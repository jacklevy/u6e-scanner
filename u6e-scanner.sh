#!/bin/sh
set -eu

# Fast per-client WiFi monitor for Ubiquiti U6 Enterprise
# Monitors: signal strength (RSSI), SNR, TX retry%, throughput floors (UL/DL p5)
# Data sources per station:
# - hostapd_cli all_sta: signal (dBm), tx_packets (batch call per interface)
# - iw dev <IF> station get <MAC>: tx retries, tx failed, tx/rx bytes (per-station call)
# - iwconfig: noise floor per interface (for SNR calculation)
# - mca-dump: hostname/IP mapping (background refresh every 60s)
#
# Key optimizations:
# - Band info cached (avoid repeated iw dev info calls)
# - Noise map cached for NOISE_CACHE_SEC seconds (default 10s) - physical property, changes slowly
# - Single iw station get call per MAC extracts all metrics (retries, failed, bytes)
# - Duplicate parsing code eliminated via process_station_iw helper
# - Removed inline hostname fill to avoid blocking main loop
# - Supports both ath* (firmware <=6.6) and wifi*ap* (firmware >=6.7) interface names
#
# U6 Enterprise wireless client monitor
#
# U6E environment and runtime assumptions (validated on device):
# - AP-mode VAP interfaces: firmware <=6.6.x uses "ath*" (e.g., ath5, ath4); firmware >=6.7.x uses "wifi*ap*" (e.g., wifi0ap0, wifi1ap3). Non-AP/dummy like dumtxvap* are ignored.
# - Shell/runtime: POSIX sh (BusyBox ash). Avoid Bashisms and GNU-only flags.
# - Tools available: hostapd_cli, iw, mca-dump, awk, sed, grep, ubus, iwconfig/iwpriv; ethtool present but no athX RF stats. No usleep.
# - hostapd_cli provides per-station: signal= (RSSI dBm), tx_packets= (cumulative).
# - iw station (dump/get) provides: tx retries, tx failed, tx bytes, rx bytes (present on U6E). "dump" may be empty intermittently → fallback to per-station "get".
# - mca-dump JSON is present and used to build a hostname map and, optionally, SSID mapping.
# - BusyBox-safe parsing throughout; avoid GNU-only extensions (e.g., sed -r). When reading TSV, prefer:
#     while IFS="$(printf '\t')" read -r col1 col2 ...; do ...; done
#   to ensure robust tab parsing under BusyBox. Always guard empty fields and treat missing counters as zero.
# - All volatile and persisted state lives under /tmp/u6e-scanner/ (this script's BASE_DIR).
#
# Cadence, performance and files:
# - Refresh cadence: REFRESH_MS (default 1000ms, ~1 Hz). sleep_ms tolerates no-usleep by using fractional sleep or whole seconds.
# - Only query VAPs with clients (IFACES=auto). Cache iface→SSID. Deduplicate by MAC keeping strongest signal across radios. Sort UI by SNR desc (fallback to signal when noise unknown).
# - Snapshots (atomic):
#   * cur.tsv: current deduplicated snapshot across ifaces (strongest signal per MAC)
#              Fields (tab-separated): band, ssid, mac, hostname, signal, tx_packets, tx_retries, tx_failed, ts, iface
#   * prev.tsv: previous snapshot for interval deltas
#   * ui_pre.tsv / ui_core.tsv: formatted/sorted rows for on-screen display
# - Per-interface parsed inputs (ephemeral): <iface>_hostapd.tsv, <iface>_iw.tsv
# - Rolling-window histories: window/<mac>.hist containing lines: "<ts> <tx_packets> <tx_retries> <tx_failed>"
# - Per-MAC bytes histories: bytes/<mac>.hist containing lines: "<ts> <tx_bytes> <rx_bytes>" collected via "iw dev <iface> station get <mac>"
# - Hostname cache: hostnames.tsv (periodic, from mca-dump); ssid.tsv (iface→SSID); ifaces.txt (active ath* with clients)
# - Per-band noise map: noise.tsv with lines "<Band>\t<Noise dBm>", built from iwconfig per cycle (averaged per band)
# - DNS reverse map: dnsnames.tsv with lines "<mac>\t<dnsname>" (optional feature). Built once-per-run per MAC on first sight; persisted across runs.
# - Command wrappers & niceness:
#   * MCA_DUMP_BIN_RAW, IW_BIN_RAW, HOSTAPD_CLI_BIN_RAW resolve to the binaries; wrappers MCA_DUMP_BIN, IW_BIN, HOSTAPD_CLI_BIN are used everywhere.
#   * NICE_BG (default 1) prepends "nice -n 15" to all wrapper commands to reduce impact; set NICE_BG=0 to disable.
#   * You can override *_BIN*_RAW via env to point at alternate paths.

# Runtime flow and timers (steady-state):
# - Each refresh (every REFRESH_MS):
#   1) Optionally clear/move cursor for in-place UI rewrite (first frame clears, subsequent frames use ESC[H/ESC[K).
#   2) Build SSID map once (cached in ssid.tsv); compute/refresh active AP-mode IFACES when needed.
#   3) For each active AP iface:
#      - hostapd_cli all_sta (one call) → parse per-station MAC, signal, tx_packets into <iface>_hostapd.tsv.
#      - iw station get (one call per station via process_station_iw helper): parse tx retries, tx failed, tx bytes, rx bytes.
#        • Single iw call extracts all metrics; bytes histories appended when activity exceeds P5_MIN_DELTA_BYTES threshold.
#      - Merge hostapd+iw by MAC; attach hostname from hostnames.tsv; write TEMP_RAW rows.
#   4) Deduplicate by MAC across radios, keeping the strongest signal; publish cur.tsv atomically and keep prev.tsv for deltas.
#   5) Append window/<mac>.hist from cur.tsv (ts, tx_packets, tx_retries, tx_failed); prune old lines beyond the trailing window.
#   6) Compute and render UI rows (deltas, interval retry ratio, rolling TxRetry%, SNR, optional UL_p5/DL_p5), sort by SNR.
# - Background/periodic tasks:
#   • Hostname updater (rebuild_hostname_map): runs every HOST_CACHE_SEC when HOSTMAP_MODE=periodic; produces hostnames.tsv atomically.
#   • Auto IFACE refresh (compute_active_ifaces): runs every HOST_CACHE_SEC alongside hostmap; keeps only AP-mode with clients (ath* or wifi*ap*).
#   • Noise map: cached and refreshed every NOISE_CACHE_SEC (default 10s); saved to noise.tsv; used to compute SNR at render time.
# - Caching/atomicity:
#   • cur.tsv/prev.tsv are atomically published; ui_pre.tsv/ui_core.tsv reflect the current frame.
#   • Hostnames consumed from hostnames.tsv (background updater); empty map tolerated for first few seconds.
#   • Band info (2.4GHz/5GHz/6GHz) cached per-interface in band_cache.tsv to avoid repeated iw info calls.
#   • Noise map cached for NOISE_CACHE_SEC seconds (default 10s) - physical property changes slowly.
#   • All shared files are written atomically or with temp files to avoid partial reads.
# - CPU-sensitive calls (optimized):
#   • hostapd_cli all_sta (per iface with clients) - single batch call, ~100ms each
#   • iw station get (once per station per refresh) - single call extracts retries, failed, and bytes, ~100-150ms each ⚠️ BOTTLENECK
#   • iw dev info (band detection) - cached per interface, queried only once per run
#   • iwconfig (noise floor) - cached for NOISE_CACHE_SEC seconds (default 10s), ~50ms per interface when refreshed
#   • mca-dump runs in background only every HOST_CACHE_SEC (60s), niced when NICE_BG=1.
#
# Rolling-window TX Retry% (default window 30s, configurable via RETRY_WINDOW_SEC):
# - For each MAC, keep cumulative counters in window/<mac>.hist at each cycle using the snapshot timestamp.
# - For current snapshot ts, choose the baseline just before cutoff ts = ts - RETRY_WINDOW_SEC (or earliest kept if none before cutoff).
# - Compute window deltas: wtx = tx_packets_delta, wr = tx_retries_delta, wf = tx_failed_delta.
# - Select denominator by WIN_FORMULA:
#   * r1: denom = wtx
#   * r2 (default): denom = wtx + wf
#   * r3: denom = wtx + wf + wr
#   Windowed retry% = wr * 100 / denom (0 if denom==0).
# - Gating (policy): by default (WIN_PARTIAL=0) the windowed value is blank until full window age has elapsed AND denom>0; set WIN_PARTIAL=1 to display immediately during short tests.
# - Per-interval retry ratio shown in UI is retry/(tx+f) = dr / (dtx+df).
#   The retry/tx variant is computed internally (for future use) but not displayed.
#   Both use per-cycle deltas between prev.tsv and cur.tsv.
#
# Throughput floors (UL_p5/DL_p5) over RETRY_WINDOW_SEC:
# - For each MAC, collect cumulative tx/rx bytes into bytes/<mac>.hist as lines: "<ts> <tx_bytes> <rx_bytes>" using iw ... station get.
# - During render, scan the history within the window and compute 1s UL/DL throughputs (KB/s) from bytes deltas.
# - Approximate 5th percentile (p5) at 1 Hz by selecting the 2nd-smallest sample in the window (or the only sample if there is one).
# - Display is gated the same as TxRetry%: blank until a full window unless WIN_PARTIAL=1.
# - Optimizations:
#   * Single iw call per station: retries/failed and bytes are parsed together to avoid extra iw passes.
#   * Activity-gated writes: only append when Δtx_bytes or Δrx_bytes ≥ P5_MIN_DELTA_BYTES to avoid idle noise.
#   * Toggle via P5_ENABLE=0 to disable p5 collection & display entirely.
#
# SNR and sorting:
# - Per-band noise is gathered each cycle from iwconfig and saved to noise.tsv; values are averaged per band (2.4/5/6GHz).
# - SNR(dB) = RSSI (signal dBm) - NoiseFloor (dBm). If no valid noise for a band (e.g., > -40 dBm or missing), SNR is blank.
# - The UI includes an SNR(dB) column and sorts rows by SNR descending; if SNR is blank, sorts by signal instead.
# - This feature does not change the snapshot schema (cur.tsv/prev.tsv); it is computed at render time from band→noise mapping.
#
# Interface selection and host mapping:
# - IFACES=auto scans iw dev for AP-mode ath* and includes only those with stations (hostapd_cli all_sta; iw dump fallback to per-station get).
# - Hostnames are built periodically from mca-dump: union of sta_table hostname plus display_name/device_name when present. Writes hostnames.tsv atomically via hostnames.tsv.new.<pid> then mv.
# - On cold start, if hostnames.tsv is empty, perform a lightweight inline parse once. If a fresh .new exists, finalize or read it to avoid blanks.
# - SSIDs are mapped via hostapd_cli get_config (fast) with mca-dump fallback.
#
# Important env vars (defaults inlined below):
# - REFRESH_MS=1000         : UI and sampling cadence in milliseconds (1 Hz default, 2000ms realistic with many clients)
# - NOISE_CACHE_SEC=10      : Noise map cache lifetime in seconds (10s default; noise floor changes slowly)
# - RETRY_WINDOW_SEC=30     : Rolling window length for TXRetry%
# - WIN_FORMULA=r2          : r1|r2|r3 denominator choice for windowed retry%
# - WIN_PARTIAL=0           : 0=blank until full window; 1=show partial values immediately
# - IFACES=auto             : Space-separated ath* list or "auto" discovery
# - USE_IW=1                : 1=use iw station dump/get for retries/failed; 0=skip iw (hostapd-only)
# - IW_GET_ONLY=1           : 1=skip iw "station dump" and only use per-station "station get"
# - P5_ENABLE=1             : 1=collect bytes and compute UL_p5/DL_p5; 0=disable p5
# - P5_MIN_DELTA_BYTES=1    : Minimum Δbytes to treat a sample as active for p5 histories
# - NICE_BG=1               : 1=run heavy external commands via nice -n 15; 0=normal priority
# - HIDE_IDLE=0             : Hide rows with zero tx in the last interval
# - HOSTMAP_MODE=periodic   : Hostname builder loop; "once" for single run
# - HOST_CACHE_SEC=60       : Hostname/iface refresh period
# - TIMERS=0                : 1=debug timestamps to stderr and debug.log; DEBUG_WIN=1 enables window diagnostics in win_dbg.txt
#
# Implementation overview (distilled control flow and cadences):
# - Main loop cadence: REFRESH_MS (default 1000ms, realistic 2000ms with 20+ clients)
#   • Per frame: cached noise map (refreshed every NOISE_CACHE_SEC); collect per-iface hostapd_cli all_sta once; per-station iw get for retries/failed/bytes; merge -> cur.tsv;
#     dedupe by strongest signal; append window histories; render UI. No mca-dump or inline hostname fill in main loop.
# - Hostname/DNS/IP enrichment cadence: HOST_CACHE_SEC (default 60s), managed by a detached background updater started on each run
#   • On each rebuild cycle, we do exactly one mca-dump snapshot and reuse it for everything in that cycle:
#     1) Hostname parsing:
#        - parse sta_table for (mac, hostname)
#        - second pass over full dump to find (mac, display_name|device_name) fallbacks
#        - merge precedence: sta_table row wins; fallbacks fill missing. Atomic write to hostnames.tsv
#     2) IP extraction + reverse DNS (dnsname column):
#        - extract (mac, ip) primarily from sta_table; merge into ipmap.tsv (lowercased mac keys), persisted across runs
#        - for each (mac, ip) not in dnsnames.tsv, run nslookup against the resolver in /etc/resolv.conf
#          parsing rule: choose the Address line whose 3rd field equals the queried IP and emit the last field ($NF) as the hostname; strip trailing ".lan"
#        - append (mac, dnsname) to dnsnames.tsv (persisted). Logging (when TIMERS=1):
#          "dns: ip pairs=… dns_rows=… ns=…" and per-lookup "dns: hit mac=… ip=… name=…" or "dns: miss …"
#   • On first run, a one-shot init step (init_ip_dns_once) performs the IP/DNS enrichment immediately using one mca-dump so UI shows IP/dnsname within seconds.
# - Reuse and throttling:
#   • mca-dump is never run more than once per rebuild cycle; both hostname and IP/DNS enrichment share the same snapshot file.
#   • iw station dump is avoided by default on U6E (IW_GET_ONLY=1); per-station iw get is used once per client per refresh.
#
# Data files and schemas (all under BASE_DIR=/tmp/u6e-scanner):
# - cur.tsv, prev.tsv (TSV, atomic):
#   band, ssid, mac, hostname, signal, tx_packets, tx_retries, tx_failed, ts, iface
# - window/<mac>.hist: "ts tx_packets tx_retries tx_failed"
# - bytes/<mac>.hist:  "ts tx_bytes rx_bytes"
# - noise.tsv:         per-band average noise: "Band<TAB>Noise_dBm"
# - hostnames.tsv:     hostname map from mca-dump (mac<TAB>hostname)
# - ipmap.tsv:         IP map from mca-dump sta_table (mac<TAB>ip) persisted across runs
# - dnsnames.tsv:      PTR-derived names (mac<TAB>dnsname-without-.lan) persisted across runs
# - band_cache.tsv:    interface band mapping (iface<TAB>band) cached for performance
# - ssid.tsv, ifaces.txt: caches for SSIDs and active AP VAPs
# - ui_pre.tsv, ui_core.tsv: current frame rows (for debugging/viewing)
#
# UI columns (left→right) and sorting:
# - band, ssid, dnsname, hostname, ip, mac, d_tx, d_r, d_TxR%, TxR%, sig, snr, UL_p5, DL_p5
#   • Timestamp shown at bottom after table: "Last update: HH:MM:SS"
#   • Sort key: snr desc when known, else signal desc. snr = signal - noise[band] when noise ≤ -40 dBm.
#
# CLI flags:
# - -h <hostname>[,host2,…]: bold rows whose hostname matches (multiple -h accepted)
# - -d <dnsname>[,dns2,…]:   bold rows whose dnsname (reverse-DNS, sans ".lan") matches (multiple -d accepted)
#
# BusyBox/firmware specifics encoded in code:
# - No usleep; sleep_ms handles fractional sleep or seconds fallback.
# - hostapd_cli all_sta gives signal and tx_packets; iw station get gives retries/failed/bytes; iw station dump unreliable on U6E.
# - PTR parsing targets BusyBox nslookup format: picks Address line for the queried IP and emits $NF; strips a trailing ".lan" suffix.
# - All merges are atomic and all TSV reads guard empty fields; MAC keys are lowercased where appropriate for stable maps.
#
# Verified-on-device notes:
# - Firmware <=6.6.77: AP interfaces named ath0..ath8 (e.g., ath2, ath4, ath5, ath6)
# - Firmware >=6.7.33: AP interfaces renamed to wifi*ap* (e.g., wifi0ap0, wifi1ap3, wifi2ap6). Script now supports both naming schemes.
# - iw shows tx packets/retries/failed; hostapd_cli shows signal and tx_packets. These are sufficient to compute both interval and window metrics at 1Hz.
# - On this firmware, "iw dev <if> station dump" frequently returns no station blocks even when clients exist. Per-station
#   "iw dev <if> station get <mac>" reliably returns "tx retries" and "tx failed". Use IW_GET_ONLY=1 to skip dump and go direct.
# - U6E note: "iw ... station dump" is effectively non-functional on this device/firmware (reports 0 stations even when clients exist).
#   The dump path remains implemented for other models/firmware where it may work and be cheaper than per-station get.
# - Firmware >=6.7.33: usleep not available, fractional sleep not working; sleep_ms falls back to whole seconds. 1 Hz cadence still stable.
# - Firmware <=6.6.77: usleep not available but fractional sleep works.
# - Recommended defaults on this device: REFRESH_MS=1000, IW_GET_ONLY=1, USE_IW=1, NICE_BG=1, HOSTMAP_MODE=periodic, HOST_CACHE_SEC=60,
#   P5_ENABLE=1, WIN_PARTIAL=0. Background hostname/iface refresh runs on HOST_CACHE_SEC cadence independent of REFRESH_MS.
# - mca-dump path is /usr/bin/mca-dump (symlink to mca.sh). "sta_table" may be empty ([]). The parser's secondary pass (parse_any)
#   finds hostnames via keys like display_name/device_name; hostname mapping works even when sta_table is empty.
# - With tx_failed=0 (common), r1 and r2 are numerically identical; r3 will be slightly lower as it includes retries in the denominator.
# - Rolling-window gating behaves as designed: TxRetry% is blank until a full RETRY_WINDOW_SEC elapses (unless WIN_PARTIAL=1).
# - SNR column: SNR = RSSI (signal dBm) - NoiseFloor (dBm). Noise is read from iwconfig per AP VAP and averaged per band
#   (2.4GHz/5GHz/6GHz). If a band has no valid noise value, SNR is left blank. Typical noise observed: 2.4GHz≈-97 dBm, 5/6GHz≈-93 dBm.
# - Interfaces: Keep IFACES=auto to avoid slow empty cycles. Auto-discovery checks both ath* and wifi*ap* patterns.
# - Performance cautions: iw is relatively slow; do not iterate all VAPs blindly; avoid non-POSIX flags; use atomic publishes; treat missing counters as zero and guard negative deltas after roam/reassoc.
# - Pitfalls to avoid: never truncate shared state; do not assume iw dump always has stations; exclude dumtxvap* interfaces; use interface pattern ^(ath[0-9]+|wifi[0-9]+ap[0-9]+)$ for AP-mode.

# Output (per refresh):
# band  ssid  dnsname  hostname  ip  mac  d_tx  d_r  d_TxR%  TxR%  sig  snr  UL_p5  DL_p5
# (Timestamp displayed at bottom after a blank line: "last updated: HH:MM:SS")
# Notes:
# - snr is computed as signal - per-band NoiseFloor; noise is taken from iwconfig each cycle and averaged per band.
# - Columns d_tx and d_r are per-refresh interval deltas; d_TxR% uses those deltas.
# - TxRetry% is the rolling-window value over RETRY_WINDOW_SEC using WIN_FORMULA (default r2).
# - Rows are deduped per-MAC by strongest signal across radios and sorted by SNR desc (fallback to signal when noise unknown).
# - Use "-h <hostname>" (repeated or comma-separated) to bold multiple hostnames, e.g., -h "jackbookpro,Downstairs-TV" -h "Pixel-10-Pro".
# - Use "-d <dnsname>" similarly to bold rows by dnsname.
# - TTY refresh: first frame clears the screen; subsequent frames move cursor home and clear each printed line to EOL (ESC[H + ESC[K) to
#   minimize flicker. If the new frame has fewer rows, extra cleared blank lines are printed. Last frame line count is tracked in ui_lines.count.

BASE_DIR="/tmp/u6e-scanner"
mkdir -p "$BASE_DIR" 2>/dev/null || true
MAIN_PID_FILE="$BASE_DIR/main.pid"
STATE_PREV="$BASE_DIR/prev.tsv"
STATE_CUR="$BASE_DIR/cur.tsv"
MAP_FILE="$BASE_DIR/hostnames.tsv"
PID_FILE="$BASE_DIR/hostmap.pid"
LOCK_DIR="$BASE_DIR/hostmap.lock"
SSID_MAP_FILE="$BASE_DIR/ssid.tsv"
IFACES_FILE="$BASE_DIR/ifaces.txt"
WINDOW_DIR="$BASE_DIR/window"
BYTES_DIR="$BASE_DIR/bytes"
NOISE_FILE="$BASE_DIR/noise.tsv"
UI_COUNT_FILE="$BASE_DIR/ui_lines.count"
DNS_MAP_FILE="$BASE_DIR/dnsnames.tsv"
IP_MAP_FILE="$BASE_DIR/ipmap.tsv"
BAND_CACHE_FILE="$BASE_DIR/band_cache.tsv"
NOISE_LAST_UPDATE_FILE="$BASE_DIR/noise.lastupdate"
REFRESH_MS="${REFRESH_MS:-2000}"
NOISE_CACHE_SEC="${NOISE_CACHE_SEC:-10}"
HIDE_IDLE="${HIDE_IDLE:-0}"
HOST_CACHE_SEC="${HOST_CACHE_SEC:-60}"
TIMERS="${TIMERS:-0}"
HOSTMAP_MODE="${HOSTMAP_MODE:-periodic}"
IFACES="${IFACES:-auto}"
RETRY_WINDOW_SEC="${RETRY_WINDOW_SEC:-30}"
MCA_DUMP_BIN_RAW="${MCA_DUMP_BIN_RAW:-$(command -v mca-dump 2>/dev/null || echo /usr/bin/mca-dump)}"
IW_BIN_RAW="${IW_BIN_RAW:-$(command -v iw 2>/dev/null || echo /usr/sbin/iw)}"
HOSTAPD_CLI_BIN_RAW="${HOSTAPD_CLI_BIN_RAW:-$(command -v hostapd_cli 2>/dev/null || echo /usr/sbin/hostapd_cli)}"
NICE_BG="${NICE_BG:-1}"
if [ "${NICE_BG}" = "1" ]; then
    NICE_PREFIX="nice -n 15 "
else
    NICE_PREFIX=""
fi
MCA_DUMP_BIN="${NICE_PREFIX}${MCA_DUMP_BIN_RAW}"
IW_BIN="${NICE_PREFIX}${IW_BIN_RAW}"
HOSTAPD_CLI_BIN="${NICE_PREFIX}${HOSTAPD_CLI_BIN_RAW}"
NSLOOKUP_BIN_RAW="${NSLOOKUP_BIN_RAW:-$(command -v nslookup 2>/dev/null || echo /usr/bin/nslookup)}"
NSLOOKUP_BIN="${NSLOOKUP_BIN_RAW}"
DBG_LOG="$BASE_DIR/debug.log"
USE_IW="${USE_IW:-1}"
WIN_PARTIAL="${WIN_PARTIAL:-0}"
WIN_FORMULA="${WIN_FORMULA:-r2}"
IW_GET_ONLY="${IW_GET_ONLY:-1}"
P5_ENABLE="${P5_ENABLE:-1}"
P5_MIN_DELTA_BYTES="${P5_MIN_DELTA_BYTES:-1}"
DNSNAME_ENABLE="${DNSNAME_ENABLE:-1}"
# Interval debug toggle: when 1, write per-row packet deltas and ratios to interval_dbg.txt
DEBUG_INTERVAL="${DEBUG_INTERVAL:-0}"
# Reset volatile state at cold start so no prior run contaminates deltas/window
reset_volatile_state() {
    rm -f "$BASE_DIR/prev.tsv" "$BASE_DIR/cur.tsv" 2>/dev/null || true
    rm -f "$BASE_DIR"/*_hostapd.tsv "$BASE_DIR"/*_iw.tsv 2>/dev/null || true
    rm -rf "$BASE_DIR/window" 2>/dev/null || true
    rm -f "$BASE_DIR/ui_lines.count" "$BASE_DIR/band_cache.tsv" "$BASE_DIR/noise.lastupdate" 2>/dev/null || true
    # Remove any leftover temp .new files from prior interrupted runs
    rm -f "$BASE_DIR"/hostnames.tsv.new.* "$BASE_DIR"/ifaces.txt.new.* 2>/dev/null || true
    # DNS/IP maps, SSID map, and noise map are persisted across runs for faster startup
}
# Ensure single instance of the main script
if [ -f "$MAIN_PID_FILE" ]; then
    old_main=$(cat "$MAIN_PID_FILE" 2>/dev/null || echo 0)
    if [ -n "$old_main" ] && kill -0 "$old_main" 2>/dev/null; then
        echo "Another scan.sh is already running (pid=$old_main). Exiting." >&2
        exit 1
    fi
fi
echo $$ > "$MAIN_PID_FILE" 2>/dev/null || true

# Optional highlight targets from CLI: -h <hostname>[,host2,host3] and -d <dnsname>[,dns2,dns3]
HILITE_HOSTS=""
HILITE_DNS=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h)
            shift
            if [ $# -gt 0 ]; then
                val="$1"
                # Accumulate comma-separated values; support multiple -h occurrences
                if [ -n "$val" ]; then
                    if [ -z "$HILITE_HOSTS" ]; then HILITE_HOSTS="$val"; else HILITE_HOSTS="$HILITE_HOSTS,$val"; fi
                fi
            fi
            shift || true
            ;;
        -d)
            shift
            if [ $# -gt 0 ]; then
                val="$1"
                # Accumulate comma-separated values; support multiple -d occurrences
                if [ -n "$val" ]; then
                    if [ -z "$HILITE_DNS" ]; then HILITE_DNS="$val"; else HILITE_DNS="$HILITE_DNS,$val"; fi
                fi
            fi
            shift || true
            ;;
        *)
            shift
            ;;
    esac
done

log_ts() {
    # Print timestamped debug lines when TIMERS=1
    [ "$TIMERS" = "1" ] || return 0
    printf "%s %s\n" "$(date +%H:%M:%S)" "$*" >&2
    printf "%s %s\n" "$(date +%H:%M:%S)" "$*" >> "$DBG_LOG" 2>/dev/null || true
}

# Sleep helper that accepts milliseconds
sleep_ms() {
    ms="$1"
    [ -z "$ms" ] && ms=1000
    # Prefer usleep if available (including via busybox)
    if command -v usleep >/dev/null 2>&1; then
        usleep "$((ms * 1000))"
        return 0
    fi
    if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx usleep; then
        busybox usleep "$((ms * 1000))"
        return 0
    fi
    secs=$(awk -v m="$ms" 'BEGIN{printf "%.3f", m/1000}')
    # If fractional sleep works, use it
    if sleep 0.001 2>/dev/null; then
        sleep "$secs" 2>/dev/null || true
        return 0
    fi
    # No fractional sleep available: only sleep if >=1s, else skip
    if [ "$ms" -ge 1000 ]; then
        sleep $(( (ms + 999) / 1000 ))
    fi
}

now_ms() {
    # Monotonic milliseconds from /proc/uptime
    awk '{printf "%d", $1*1000}' /proc/uptime 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}

list_ap_ifaces() {
    # List AP-mode VAP interfaces; prefer ath* and skip wifi*/dummy
    if [ -n "${IFACES:-}" ] && [ "$IFACES" != "auto" ]; then
        for i in $IFACES; do echo "$i"; done
        return 0
    fi
    if [ -s "$IFACES_FILE" ]; then
        cat "$IFACES_FILE"
        return 0
    fi
    log_ts "list_ifaces(auto): compute (cold)"
    compute_active_ifaces
    [ -s "$IFACES_FILE" ] && cat "$IFACES_FILE" || true
}

list_sta_macs() {
    # $1: iface
    $HOSTAPD_CLI_BIN -i "$1" all_sta 2>/dev/null | grep -E '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'
}

build_hostname_map() {
    # Return the path to the current hostname map; do not rebuild here.
    [ -f "$MAP_FILE" ] || : > "$MAP_FILE"
    echo "$MAP_FILE"
}

rebuild_hostname_map() {
    # Rebuild the hostname map once using a robust awk parser
    log_ts "hostmap: rebuild start"
    # Prevent overlapping rebuilds
    local rlock="$BASE_DIR/hostmap.rebuild.lock"
    if ! mkdir "$rlock" 2>/dev/null; then
        log_ts "hostmap: rebuild already in progress; skipping"
        return 0
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        # If map is empty, lock may be stale; remove and continue
        if [ ! -s "$MAP_FILE" ]; then rm -rf "$LOCK_DIR" 2>/dev/null || true; fi
    fi
    tmp_file="${MAP_FILE}.new.$$"
    : > "$tmp_file"
    parser="$BASE_DIR/parse_sta.awk"
    # Write parser atomically
    tmp_p="$parser.new.$$"
    cat > "$tmp_p" <<'AWK'
BEGIN{in_arr=0; arr_depth=0; obj_depth=0; mac=""; host=""}
function countChar(s, ch,   i,c){c=0; for(i=1;i<=length(s);i++) if (substr(s,i,1)==ch) c++; return c}
{
  if (!in_arr) {
    if (index($0,"\"sta_table\"")>0 && index($0,"[")>0) {
      in_arr=1; arr_depth = countChar($0,"[") - countChar($0,"]"); obj_depth=0; next
    }
    next
  }

  # Update array and object depths
  arr_depth += countChar($0,"[") - countChar($0,"]")
  obj_depth += countChar($0,"{") - countChar($0,"}")

  # Capture fields inside objects
  if (index($0,"\"mac\"")) { v=$0; sub(/^.*"mac"[ \t]*:[ \t]*"/,"",v); sub(/".*$/, "", v); mac=tolower(v) }
  if (index($0,"\"hostname\"")) { v=$0; sub(/^.*"hostname"[ \t]*:[ \t]*"/,"",v); sub(/".*$/, "", v); host=v }

  # When an object closes at top-level, emit
  if (obj_depth==0 && (index($0,"}")>0)) {
    if (mac!="") {
      if (host=="") host="-";
      print mac "\t" host
    }
    mac=""; host=""
  }

  # Leave sta_table when array depth returns to zero
  if (arr_depth<=0) { in_arr=0 }
}
AWK
    mv -f "$tmp_p" "$parser" 2>/dev/null || true
    # Capture a single mca-dump snapshot for this rebuild and reuse it for all parsing to minimize load
    dump_file="$BASE_DIR/mca_dump.$$.json"
    $MCA_DUMP_BIN 2>/dev/null > "$dump_file" || true
    awk -f "$parser" "$dump_file" > "$tmp_file" 2>/dev/null || true
    # Build IP map (mac -> ip) from sta_table first; fallback to generic scan later
    ip_tmp="$BASE_DIR/ipmap.$$.tsv"
    awk -v FS="," '
      BEGIN{in_arr=0; obj=0; mac=""; ip=""}
      /"sta_table"[[:space:]]*:/ && /\[/ { in_arr=1; next }
      in_arr{
        obj += gsub(/\{/,"{") - gsub(/\}/,"}")
        if (index($0,"\"mac\"")>0) { v=$0; sub(/^.*\"mac\"[ \t]*:[ \t]*\"/,"",v); sub(/\".*$/, "", v); mac=tolower(v) }
        if (index($0,"\"ip\"")>0)  { v=$0; sub(/^.*\"ip\"[ \t]*:[ \t]*\"/,"",v); sub(/\".*$/, "", v); ip=v }
        if (obj==0 && mac!="" ) { if (ip!="") printf "%s\t%s\n", mac, ip; mac=""; ip="" }
        if (obj==0 && index($0, "]")>0) { in_arr=0 }
      }
    ' "$dump_file" | sort -u > "$ip_tmp" 2>/dev/null || true
    # Second pass: search entire dump for other objects with mac + hostname or alias 'name'
    parser2="$BASE_DIR/parse_any.awk"
    tmp2="${MAP_FILE}.any.$$"
    cat > "$parser2" <<'AWK'
BEGIN{obj_depth=0; mac=""; host=""}
function countChar(s, ch,   i,c){c=0; for(i=1;i<=length(s);i++) if (substr(s,i,1)==ch) c++; return c}
{
  obj_depth += countChar($0,"{") - countChar($0,"}")
  if (index($0,"\"mac\"")) { v=$0; sub(/^.*"mac"[ \t]*:[ \t]*"/,"",v); sub(/".*$/, "", v); mac=tolower(v) }
  if (index($0,"\"hostname\"")) { v=$0; sub(/^.*"hostname"[ \t]*:[ \t]*"/,"",v); sub(/".*$/, "", v); host=v }
  # Downstairs-TV style sometimes appears under a different key, e.g., "display_name" or "device_name"
  if (host=="" && index($0,"\"display_name\"")) { v=$0; sub(/^.*"display_name"[ \t]*:[ \t]*"/,"",v); sub(/".*$/, "", v); host=v }
  if (host=="" && index($0,"\"device_name\"")) { v=$0; sub(/^.*"device_name"[ \t]*:[ \t]*"/,"",v); sub(/".*$/, "", v); host=v }
  if (index($0,"}")>0 && obj_depth<=0){
     if (mac!="" && host!=""){
        print mac "\t" host
     }
     mac=""; host=""; obj_depth=0
  }
}
AWK
    awk -f "$parser2" "$dump_file" > "$tmp2" 2>/dev/null || true
    # Merge with precedence: sta_table first, then parse_any.
    # Use union of keys so we still populate when sta_table is empty.
    tmp_all="${MAP_FILE}.all.$$"
    cat "$tmp_file" "$tmp2" > "$tmp_all" 2>/dev/null || true
    tmp_merged="${MAP_FILE}.merged.$$"
    awk -F '\t' '
      {
        mac=$1; hn=$2;
        if (mac=="" ) next;
        if (!(mac in H)) { H[mac]=(hn!=""?hn:"-"); }
        else {
          if (H[mac]=="-" && hn!="-") H[mac]=hn;
        }
      }
      END { for (mac in H) print mac "\t" H[mac]; }
    ' "$tmp_all" > "$tmp_merged" 2>/dev/null || true
    rows=$(wc -l "$tmp_merged" 2>/dev/null | awk '{print $1}')
    log_ts "hostmap: parsed rows=$rows"
    if [ -s "$tmp_merged" ]; then
        # Write atomically and in a way readers can detect mid-write: .new.<pid> then final
        tmp_out="$MAP_FILE.new.$$"
        mv -f "$tmp_merged" "$tmp_out" 2>/dev/null || true
        sync 2>/dev/null || true
        mv -f "$tmp_out" "$MAP_FILE" 2>/dev/null || true
    else
        rm -f "$tmp_merged"
    fi
    # Reverse DNS enrichment (optional, one-time per MAC per run). Build dnsnames.tsv
    if [ "$DNSNAME_ENABLE" = "1" ]; then
        # Ensure map file exists
        [ -f "$DNS_MAP_FILE" ] || : > "$DNS_MAP_FILE"
        [ -f "$IP_MAP_FILE" ] || : > "$IP_MAP_FILE"
        ns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
        [ -z "$ns" ] && ns=""
        # Extract mac and ip pairs from sta_table ip map first; fallback to generic scan if empty
        tmp_ipmac="$BASE_DIR/ips.$$"
        : > "$tmp_ipmac"
        if [ -s "$ip_tmp" ]; then
            cp -f "$ip_tmp" "$tmp_ipmac" 2>/dev/null || true
        else
            awk '
              function countChar(s,ch,  i,c){c=0; for(i=1;i<=length(s);i++) if(substr(s,i,1)==ch) c++; return c}
              BEGIN{obj=0; mac=""; ip=""}
              {
                line=$0
                obj += countChar(line,"{") - countChar(line,"}")
                if (index(tolower(line),"\"mac\"")>0) { v=line; sub(/^.*\"mac\"[ \t]*:[ \t]*\"/,"",v); sub(/\".*$/, "", v); m=tolower(v); if (m ~ /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) mac=m }
                if (index(line,"\"ip\"")>0) { v=line; sub(/^.*\"ip\"[ \t]*:[ \t]*\"/,"",v); sub(/\".*$/, "", v); ip=v }
                if (obj<=0) { if (mac!="" && ip!="") printf "%s\t%s\n", mac, ip; mac=""; ip="" }
              }
            ' "$dump_file" | sort -u > "$tmp_ipmac" 2>/dev/null || true
        fi
        # Persist/merge IPs into IP_MAP_FILE (lowercase MAC keys)
        awk -F '\t' 'BEGIN{OFS="\t"}
            FNR==NR { if($1!=""){ lm=tolower($1); ip[lm]=$2 } next }
            { if($1!=""){ lm=tolower($1); ip[lm]=$2 } }
            END{ for (m in ip) printf "%s\t%s\n", m, ip[m] }
        ' "$IP_MAP_FILE" "$tmp_ipmac" | sort -u > "$IP_MAP_FILE.new" 2>/dev/null || true
        mv -f "$IP_MAP_FILE.new" "$IP_MAP_FILE" 2>/dev/null || true

        # For each mac/ip not yet in dns map, attempt reverse lookup
        rows_ip=$(wc -l < "$tmp_ipmac" 2>/dev/null || echo 0)
        rows_dns=$(wc -l < "$DNS_MAP_FILE" 2>/dev/null || echo 0)
        log_ts "dns: ip pairs=${rows_ip} dns_rows=${rows_dns} ns=${ns:-none}"
        while IFS="\t" read -r mm ii; do
            [ -z "$mm" ] && continue
            # Skip if already have an entry
            if grep -iq "^$mm\t" "$DNS_MAP_FILE" 2>/dev/null; then continue; fi
            [ -z "$ii" ] && continue
            if [ -n "$ns" ]; then
                name=$($NSLOOKUP_BIN "$ii" "$ns" 2>/dev/null | awk -v q="$ii" '
                    # BusyBox nslookup prints multiple Address lines; choose the one for the queried IP
                    /^Address[[:space:]]+[0-9]+:/ { if ($3==q) { if (NF>=4) { print $NF; exit } } }
                ' | head -n1)
            else
                name=$($NSLOOKUP_BIN "$ii" 2>/dev/null | awk -v q="$ii" '
                    /^Address[[:space:]]+[0-9]+:/ { if ($3==q) { if (NF>=4) { print $NF; exit } } }
                ' | head -n1)
            fi
            if [ -n "$name" ]; then
                case "$name" in
                    *.lan) name=${name%".lan"} ;;
                esac
                printf "%s\t%s\n" "$mm" "$name" >> "$DNS_MAP_FILE"
                log_ts "dns: hit mac=$mm ip=$ii name=$name"
            else
                log_ts "dns: miss mac=$mm ip=$ii"
            fi
        done < "$tmp_ipmac"
        rm -f "$tmp_ipmac" 2>/dev/null || true
    fi
    rm -f "$tmp_all" 2>/dev/null || true
    rm -f "$tmp_file" "$tmp2" "$dump_file" "$ip_tmp" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    rmdir "$rlock" 2>/dev/null || true
}

# Build per-band noise map from iwconfig (average across AP-mode VAPs per band)
compute_noise_map() {
	# Create a temporary list of (band, noise) pairs
	tmp="$BASE_DIR/noise_pairs.$$.tsv"
	: > "$tmp"
	for ifc in $(iw dev 2>/dev/null | awk '$1=="Interface"{i=$2} $1=="type" && $2=="AP"{print i}' | grep -E '^(ath[0-9]+|wifi[0-9]+ap[0-9]+)$'); do
		band=$(get_band_from_iface "$ifc")
		# Extract numeric Noise level (e.g., -93) specifically from "Noise level=..."
		noise=$(iwconfig "$ifc" 2>/dev/null | awk '
			tolower($0) ~ /noise level=/ {
				line=$0
				sub(/^.*[Nn]oise[[:space:]]+level=/, "", line)
				sub(/[[:space:]]*dBm.*$/, "", line)
				gsub(/[^-0-9]/, "", line)
				if (line!="") { print line; exit }
			}
		') || noise=""
		[ -n "$noise" ] && printf "%s\t%s\n" "$band" "$noise" >> "$tmp"
	done
	# Aggregate by band using integer average (busybox-safe)
	tmp_out="$BASE_DIR/noise.$$.tsv"
	awk -F '\t' '{ b=$1; n=$2+0; c[b]++; s[b]+=n } END { for (b in s) printf "%s\t%d\n", b, (c[b]>0 ? int(s[b]/c[b]) : 0) }' "$tmp" > "$tmp_out" 2>/dev/null || true
	mv -f "$tmp_out" "$NOISE_FILE" 2>/dev/null || true
	rm -f "$tmp" 2>/dev/null || true
	# Record update time
	date +%s > "$NOISE_LAST_UPDATE_FILE" 2>/dev/null || true
}

compute_noise_map_cached() {
	# Cached noise map: only update every NOISE_CACHE_SEC seconds
	# Noise floor is a physical property that changes very slowly
	now=$(date +%s)
	last_update=0
	if [ -f "$NOISE_LAST_UPDATE_FILE" ]; then
		last_update=$(cat "$NOISE_LAST_UPDATE_FILE" 2>/dev/null || echo 0)
	fi
	age=$((now - last_update))
	
	# Use cached noise if recent enough and file exists
	if [ "$age" -lt "$NOISE_CACHE_SEC" ] && [ -s "$NOISE_FILE" ]; then
		log_ts "noise: using cache (age=${age}s)"
		return 0
	fi
	
	# Cache expired or missing: refresh
	log_ts "noise: refresh (age=${age}s)"
	compute_noise_map
}

start_hostmap_updater() {
    # Start a detached background updater if not already running
    if [ -s "$MAP_FILE" ]; then
        sz=$(wc -c "$MAP_FILE" 2>/dev/null | awk '{print $1}')
    else
        sz=0
    fi
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null || echo 0)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if [ "${sz:-0}" -gt 0 ]; then
                log_ts "hostmap: updater already running (pid=$pid)"
                return 0
            fi
            # Map empty while updater running: restart it
            log_ts "hostmap: updater running but map empty; restarting"
            kill "$pid" 2>/dev/null || true
            rm -f "$PID_FILE" 2>/dev/null || true
        fi
    fi
    if [ "$HOSTMAP_MODE" = "once" ]; then
        (rebuild_hostname_map) >/dev/null 2>&1 &
        echo $! > "$PID_FILE" 2>/dev/null || true
        log_ts "hostmap: one-shot rebuild started pid=$(cat "$PID_FILE" 2>/dev/null)"
        return 0
    fi
    if [ "$TIMERS" = "1" ]; then
        (
            while :; do
                rebuild_hostname_map
                # In auto IFACES mode, refresh active interface list along with host cache
                if [ "$IFACES" = "auto" ]; then compute_active_ifaces; fi
                :
                sleep "$HOST_CACHE_SEC" || exit 0
            done
        ) &
    else
        (
            while :; do
                rebuild_hostname_map
                if [ "$IFACES" = "auto" ]; then compute_active_ifaces; fi
                :
                sleep "$HOST_CACHE_SEC" || exit 0
            done
        ) >/dev/null 2>&1 &
    fi
    echo $! > "$PID_FILE" 2>/dev/null || true
    log_ts "hostmap: updater started pid=$(cat "$PID_FILE" 2>/dev/null)"
    # Immediate refresh on first-ever start only (ensure we produce a map even when sta_table is empty)
    STARTED_FLAG="$BASE_DIR/hostmap.started"
    if [ ! -f "$STARTED_FLAG" ]; then
        (rebuild_hostname_map) >/dev/null 2>&1 &
        if [ "$IFACES" = "auto" ]; then (compute_active_ifaces) >/dev/null 2>&1 & fi
        : > "$STARTED_FLAG"
    fi
}

stop_hostmap_updater() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null || echo 0)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log_ts "hostmap: updater stopped (pid=$pid)"
        fi
        rm -f "$PID_FILE" 2>/dev/null || true
    fi
}

cleanup() {
    log_ts "cleanup start"
    stop_hostmap_updater
    # Remove temporary/volatile files
    rm -f "$BASE_DIR"/*_hostapd.tsv "$BASE_DIR"/*_iw.tsv 2>/dev/null || true
    rm -rf "$WINDOW_DIR" "$BYTES_DIR" 2>/dev/null || true
    rm -f "$BASE_DIR/prev.tsv" "$BASE_DIR/cur.tsv" "$BASE_DIR/band_cache.tsv" "$BASE_DIR/ui_lines.count" "$BASE_DIR/noise.lastupdate" 2>/dev/null || true
    rm -f "$BASE_DIR"/hostnames.tsv.new.* "$BASE_DIR"/ifaces.txt.new.* 2>/dev/null || true
    # Remove hostname updater locks/flags
    rm -rf "$LOCK_DIR" "$BASE_DIR/hostmap.rebuild.lock" 2>/dev/null || true
    rm -f "$BASE_DIR/hostmap.started" 2>/dev/null || true
    # Best-effort: kill any lingering hostname parse awk processes
    for pid in $(ps w 2>/dev/null | grep -E 'awk -f /tmp/u6e-scanner/parse_(sta|any)\.awk' | grep -v grep | awk '{print $1}'); do
        kill "$pid" 2>/dev/null || true
    done
    # Best-effort: kill any lingering background scan.sh subshells
    for pid in $(ps w 2>/dev/null | grep -E '\{scan\.sh\} /bin/sh ./scan\.sh' | grep -v grep | awk '{print $1}'); do
        [ "$pid" = "$$" ] && continue
        kill "$pid" 2>/dev/null || true
    done
    rm -f "$MAIN_PID_FILE" 2>/dev/null || true
    log_ts "cleanup done"
    exit 0
}

enrich_ip_dns_from_dump() {
    # $1: dump_file (mca-dump JSON)
    [ "$DNSNAME_ENABLE" = "1" ] || return 0
    dump_file="$1"
    # Build IP pairs from sta_table
    ip_tmp="$BASE_DIR/ips.enrich.$$.tsv"
    awk -v FS="," '
      BEGIN{in_arr=0; obj=0; mac=""; ip=""}
      /"sta_table"[[:space:]]*:/ && /\[/ { in_arr=1; next }
      in_arr{
        obj += gsub(/\{/ ,"{") - gsub(/\}/ ,"}")
        if (index($0,"\"mac\"")>0) { v=$0; sub(/^.*\"mac\"[ \t]*:[ \t]*\"/,"",v); sub(/\".*$/, "", v); mac=tolower(v) }
        if (index($0,"\"ip\"")>0)  { v=$0; sub(/^.*\"ip\"[ \t]*:[ \t]*\"/,"",v); sub(/\".*$/, "", v); ip=v }
        if (obj==0 && mac!="" ) { if (ip!="") printf "%s\t%s\n", mac, ip; mac=""; ip="" }
        if (obj==0 && index($0, "]")>0) { in_arr=0 }
      }
    ' "$dump_file" | sort -u > "$ip_tmp" 2>/dev/null || true
    [ -f "$IP_MAP_FILE" ] || : > "$IP_MAP_FILE"
    [ -f "$DNS_MAP_FILE" ] || : > "$DNS_MAP_FILE"
    # Merge IPs into persistent map
    awk -F '\t' 'BEGIN{OFS="\t"}
        FNR==NR { if($1!=""){ lm=tolower($1); ip[lm]=$2 } next }
        { if($1!=""){ lm=tolower($1); ip[lm]=$2 } }
        END{ for (m in ip) printf "%s\t%s\n", m, ip[m] }
    ' "$IP_MAP_FILE" "$ip_tmp" | sort -u > "$IP_MAP_FILE.new" 2>/dev/null || true
    mv -f "$IP_MAP_FILE.new" "$IP_MAP_FILE" 2>/dev/null || true
    # PTR lookups for MACs missing in dns map
    ns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
    [ -z "$ns" ] && ns=""
    rows_ip=$(wc -l < "$ip_tmp" 2>/dev/null || echo 0)
    rows_dns=$(wc -l < "$DNS_MAP_FILE" 2>/dev/null || echo 0)
    log_ts "dns: ip pairs=${rows_ip} dns_rows=${rows_dns} ns=${ns:-none}"
    while IFS="$(printf '\t')" read -r mm ii; do
        [ -z "$mm" ] && continue
        grep -iq "^$mm\t" "$DNS_MAP_FILE" 2>/dev/null && continue
        [ -z "$ii" ] && continue
        if [ -n "$ns" ]; then
            name=$($NSLOOKUP_BIN "$ii" "$ns" 2>/dev/null | awk -v q="$ii" '/^Address[[:space:]]+[0-9]+:/{ if ($3==q && NF>=4) { print $NF; exit } }' | head -n1)
        else
            name=$($NSLOOKUP_BIN "$ii" 2>/dev/null | awk -v q="$ii" '/^Address[[:space:]]+[0-9]+:/{ if ($3==q && NF>=4) { print $NF; exit } }' | head -n1)
        fi
        if [ -n "$name" ]; then
            case "$name" in *.lan) name=${name%".lan"} ;; esac
            printf "%s\t%s\n" "$mm" "$name" >> "$DNS_MAP_FILE"
            log_ts "dns: hit mac=$mm ip=$ii name=$name"
        else
            log_ts "dns: miss mac=$mm ip=$ii"
        fi
    done < "$ip_tmp"
    rm -f "$ip_tmp" 2>/dev/null || true
}

init_ip_dns_once() {
    # One-shot synchronous IP/DNS enrichment at startup to populate UI immediately
    [ "$DNSNAME_ENABLE" = "1" ] || return 0
    flag="$BASE_DIR/ipdns.initial.done"
    [ -f "$flag" ] && return 0
    dump_file="$BASE_DIR/mca_dump.init.$$.json"
    $MCA_DUMP_BIN 2>/dev/null > "$dump_file" || true
    ip_tmp="$BASE_DIR/ipmap.init.$$.tsv"
    awk -v FS="," '
      BEGIN{in_arr=0; obj=0; mac=""; ip=""}
      /"sta_table"[[:space:]]*:/ && /\[/ { in_arr=1; next }
      in_arr{
        obj += gsub(/\{/ ,"{") - gsub(/\}/ ,"}")
        if (index($0,"\"mac\"")>0) { v=$0; sub(/^.*\"mac\"[ \t]*:[ \t]*\"/,"",v); sub(/\".*$/, "", v); mac=tolower(v) }
        if (index($0,"\"ip\"")>0)  { v=$0; sub(/^.*\"ip\"[ \t]*:[ \t]*\"/,"",v); sub(/\".*$/, "", v); ip=v }
        if (obj==0 && mac!="" ) { if (ip!="") printf "%s\t%s\n", mac, ip; mac=""; ip="" }
        if (obj==0 && index($0, "]")>0) { in_arr=0 }
      }
    ' "$dump_file" | sort -u > "$ip_tmp" 2>/dev/null || true
    [ -f "$IP_MAP_FILE" ] || : > "$IP_MAP_FILE"
    [ -f "$DNS_MAP_FILE" ] || : > "$DNS_MAP_FILE"
    # Merge IPs into persistent map
    awk -F '\t' 'BEGIN{OFS="\t"}
        FNR==NR { if($1!=""){ lm=tolower($1); ip[lm]=$2 } next }
        { if($1!=""){ lm=tolower($1); ip[lm]=$2 } }
        END{ for (m in ip) printf "%s\t%s\n", m, ip[m] }
    ' "$IP_MAP_FILE" "$ip_tmp" | sort -u > "$IP_MAP_FILE.new" 2>/dev/null || true
    mv -f "$IP_MAP_FILE.new" "$IP_MAP_FILE" 2>/dev/null || true
    # PTR lookups for MACs missing in dns map
    ns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
    [ -z "$ns" ] && ns=""
    while IFS="$(printf '\t')" read -r mm ii; do
        [ -z "$mm" ] && continue
        grep -iq "^$mm\t" "$DNS_MAP_FILE" 2>/dev/null && continue
        [ -z "$ii" ] && continue
        if [ -n "$ns" ]; then
            name=$($NSLOOKUP_BIN "$ii" "$ns" 2>/dev/null | awk -v q="$ii" '/^Address[[:space:]]+[0-9]+:/{ if ($3==q && NF>=4) { print $NF; exit } }' | head -n1)
        else
            name=$($NSLOOKUP_BIN "$ii" 2>/dev/null | awk -v q="$ii" '/^Address[[:space:]]+[0-9]+:/{ if ($3==q && NF>=4) { print $NF; exit } }' | head -n1)
        fi
        if [ -n "$name" ]; then
            case "$name" in
                *.lan) name=${name%".lan"} ;;
            esac
            printf "%s\t%s\n" "$mm" "$name" >> "$DNS_MAP_FILE"
            log_ts "dns: hit mac=$mm ip=$ii name=$name"
        else
            log_ts "dns: miss mac=$mm ip=$ii"
        fi
    done < "$ip_tmp"
    : > "$flag"
    rm -f "$dump_file" "$ip_tmp" 2>/dev/null || true
}

lookup_hostname() {
    # $1: mac, $2: map_file
    grep -i -m1 "^$1\t" "$2" 2>/dev/null | cut -f2 || true
}

build_ssid_map() {
    # Build iface -> SSID map once (fast path via hostapd_cli get_config)
    [ -s "$SSID_MAP_FILE" ] && { echo "$SSID_MAP_FILE"; return; }
    : > "$SSID_MAP_FILE"
    for ifc in $($IW_BIN dev 2>/dev/null | awk '$1=="Interface"{i=$2} $1=="type" && $2=="AP"{print i}' | grep -E '^(ath[0-9]+|wifi[0-9]+ap[0-9]+)$'); do
        ssid=$($HOSTAPD_CLI_BIN -i "$ifc" get_config 2>/dev/null | awk -F= '/^ssid=/{print $2; exit}') || ssid=""
        if [ -z "$ssid" ]; then
            # Fallback: try mca-dump vap_table mapping name->essid
            ssid=$($MCA_DUMP_BIN 2>/dev/null | awk -v target="$ifc" '
                /"name"[ ]*:/ { n=$0; sub(/.*"name"[ ]*:[ ]*"/, "", n); sub(/".*/, "", n); if(n==target) capture=1; next }
                capture && /"essid"[ ]*:/ { s=$0; sub(/.*"essid"[ ]*:[ ]*"/, "", s); sub(/".*/, "", s); print s; exit }
                /\]/ { capture=0 }
            ')
        fi
        [ -z "$ssid" ] && ssid="-"
        printf "%s\t%s\n" "$ifc" "$ssid" >> "$SSID_MAP_FILE"
    done
    echo "$SSID_MAP_FILE"
}

lookup_ssid() {
    # $1: iface
    grep -m1 "^$1\t" "$SSID_MAP_FILE" 2>/dev/null | cut -f2 || echo -
}

compute_active_ifaces() {
    # Build list of AP interfaces that currently have clients
    tmp="${IFACES_FILE}.new.$$"
    : > "$tmp"
    log_ts "auto-ifaces: scan start"
    for ifc in $($IW_BIN dev 2>/dev/null | awk '$1=="Interface"{i=$2} $1=="type" && $2=="AP"{print i}' | grep -E '^(ath[0-9]+|wifi[0-9]+ap[0-9]+)$'); do
        n=$($HOSTAPD_CLI_BIN -i "$ifc" all_sta 2>/dev/null | grep -Ec '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || true)
        if [ "${n:-0}" -eq 0 ]; then
            # Fallback once via iw (slower but reliable) in case hostapd_cli briefly returns nothing
            n=$($IW_BIN dev "$ifc" station dump 2>/dev/null | grep -c '^Station ' || true)
        fi
        if [ "${n:-0}" -gt 0 ]; then echo "$ifc" >> "$tmp"; fi
    done
    prev_cnt=0; [ -s "$IFACES_FILE" ] && prev_cnt=$(wc -l < "$IFACES_FILE")
    new_cnt=0;  [ -s "$tmp" ] && new_cnt=$(wc -l < "$tmp")
    if [ "$new_cnt" -eq 0 ] && [ "$prev_cnt" -gt 0 ]; then
        # Keep previous if transiently empty
        rm -f "$tmp"
        log_ts "auto-ifaces: transient empty; keep previous -> $(tr '\n' ' ' < "$IFACES_FILE")"
        return 0
    fi
    if [ "$prev_cnt" -gt 0 ] && [ "$new_cnt" -gt 0 ] && [ "$new_cnt" -lt "$prev_cnt" ]; then
        # Merge to avoid collapsing due to transient misses
        sort -u "$tmp" "$IFACES_FILE" > "${tmp}.merged"
        mv -f "${tmp}.merged" "$IFACES_FILE"
        rm -f "$tmp"
        log_ts "auto-ifaces: merged -> $(tr '\n' ' ' < "$IFACES_FILE")"
        return 0
    fi
    if [ -s "$tmp" ]; then
        mv -f "$tmp" "$IFACES_FILE"
        log_ts "auto-ifaces: updated -> $(tr '\n' ' ' < "$IFACES_FILE")"
    else
        rm -f "$tmp"
        log_ts "auto-ifaces: no active interfaces detected"
    fi
}

get_band_from_iface() {
    # $1: iface -> 2.4GHz | 5GHz | 6GHz (cached for performance)
    # Check cache first
    if [ -s "$BAND_CACHE_FILE" ]; then
        cached=$(grep -m1 "^$1\t" "$BAND_CACHE_FILE" 2>/dev/null | cut -f2)
        if [ -n "$cached" ]; then
            echo "$cached"
            return 0
        fi
    fi
    # Cache miss: query and store
    freq=$($IW_BIN dev "$1" info 2>/dev/null | sed -n 's/.*(\([0-9][0-9]*\) MHz).*/\1/p' | head -n1) || true
    if [ -z "${freq:-}" ]; then
        echo "?"
        return 0
    fi
    if [ "$freq" -ge 5925 ]; then
        band="6GHz"
    elif [ "$freq" -ge 4900 ]; then
        band="5GHz"
    else
        band="2.4GHz"
    fi
    # Store in cache
    printf "%s\t%s\n" "$1" "$band" >> "$BAND_CACHE_FILE" 2>/dev/null || true
    echo "$band"
}

process_station_iw() {
    # Parse iw station get for a single MAC and update P5 bytes history
    # Single iw call extracts: tx retries, tx failed, tx bytes, rx bytes
    # $1=iface, $2=mac, $3=ts, $4=output_file
    local ifc="$1" mac="$2" ts="$3" outfile="$4"
    
    # Single iw station get call extracts all needed metrics
    stats=$($IW_BIN dev "$ifc" station get "$mac" 2>/dev/null | awk '
        BEGIN{tr="";tf="";txb="";rxb=""}
        /tx retries/{split($0,a,":"); gsub(/[^0-9]/,"",a[2]); tr=a[2]; next}
        /tx failed/{split($0,a,":"); gsub(/[^0-9]/,"",a[2]); tf=a[2]; next}
        /tx bytes/{split($0,a,":"); gsub(/[^0-9]/,"",a[2]); txb=a[2]; next}
        /rx bytes/{split($0,a,":"); gsub(/[^0-9]/,"",a[2]); rxb=a[2]; next}
        END{ if(tr=="") tr=0; if(tf=="") tf=0; if(txb=="") txb=0; if(rxb=="") rxb=0; printf "%s\t%s\t%s\t%s", tr, tf, txb, rxb }
    ')
    
    tr=$(echo "$stats" | cut -f1)
    tf=$(echo "$stats" | cut -f2)
    txb=$(echo "$stats" | cut -f3)
    rxb=$(echo "$stats" | cut -f4)
    
    # Write retry/failed stats to output file (schema: mac tr tf)
    printf "%s\t%s\t%s\n" "$mac" "$tr" "$tf" >> "$outfile" || true
    
    # Update P5 throughput bytes history (activity-gated to reduce noise)
    if [ "${P5_ENABLE}" = "1" ]; then
        prev_line=$(tail -n1 "$BYTES_DIR/$mac.hist" 2>/dev/null || true)
        if [ -n "$prev_line" ]; then
            prev_txb=$(echo "$prev_line" | awk '{print $2+0}')
            prev_rxb=$(echo "$prev_line" | awk '{print $3+0}')
            dtx=$((txb - prev_txb)); drx=$((rxb - prev_rxb))
            [ "$dtx" -lt 0 ] && dtx=0
            [ "$drx" -lt 0 ] && drx=0
        else
            dtx=$P5_MIN_DELTA_BYTES; drx=$P5_MIN_DELTA_BYTES
        fi
        # Only append if activity exceeds threshold (avoid idle noise in p5 calculation)
        if [ "$dtx" -ge "$P5_MIN_DELTA_BYTES" ] || [ "$drx" -ge "$P5_MIN_DELTA_BYTES" ]; then
            if echo "$mac" | grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'; then
                printf "%s %s %s\n" "$ts" "$txb" "$rxb" >> "$BYTES_DIR/$mac.hist"
            fi
        fi
    fi
}

collect_snapshot() {
    # Produce TSV rows atomically to avoid races: band    ssid    mac    host    signal    tx_packets    tx_retries    tx_failed    timestamp
    TEMP_RAW="$BASE_DIR/cur_raw.$$.tsv"
    : > "$TEMP_RAW"
    ts=$(date +%s)
    HOSTMAP=$(build_hostname_map)
    # Update per-band noise map from iwconfig for SNR calculations (cached for NOISE_CACHE_SEC seconds)
    compute_noise_map_cached >/dev/null 2>&1 || true
    # Use hostname map from background updater (empty initially, populates within 60s)
    MFILE="$MAP_FILE"
    [ -e "$MFILE" ] || : > "$MFILE"
    # Lazy finalization: if empty, check for .new files from background updater and finalize them
    if [ ! -s "$MFILE" ]; then
        for newfile in "$BASE_DIR"/hostnames.tsv.new.*; do
            [ -f "$newfile" ] && [ -s "$newfile" ] || continue
            mv -f "$newfile" "$MFILE" 2>/dev/null && log_ts "hostmap: lazy finalized $(basename "$newfile")" && break
        done
    fi
    # Build SSID map once at startup (returns immediately if already cached)
    build_ssid_map >/dev/null 2>&1 || true
    # Ensure bytes dir exists before any per-station writes during iw loops
    mkdir -p "$BYTES_DIR" 2>/dev/null || true
    faces=$(list_ap_ifaces)
    log_ts "cycle ifaces: ${faces}"
    for ifc in $faces; do
        band=$(get_band_from_iface "$ifc")
        ssid=$(lookup_ssid "$ifc")

        # Parse hostapd_cli all_sta once: mac, signal, tx_packets
        hfile="$BASE_DIR/${ifc}_hostapd.tsv"
        log_ts "if=$ifc hostapd_cli all_sta start"
        $HOSTAPD_CLI_BIN -i "$ifc" all_sta 2>/dev/null | awk 'BEGIN{sig="";txp="";mac=""}
            /^[0-9a-fA-F][0-9a-fA-F]:/ { if(mac!=""){printf "%s\t%s\t%s\n", tolower(mac), sig, txp} ; mac=$0; sig=""; txp=""; next }
            /^signal=/{split($0,a,"="); sig=a[2]; next}
            /^tx_packets=/{split($0,a,"="); txp=a[2]; next}
            /^$/ { if(mac!=""){printf "%s\t%s\t%s\n", tolower(mac), sig, txp} ; mac=""; sig=""; txp="" }
            END{ if(mac!=""){printf "%s\t%s\t%s\n", tolower(mac), sig, txp} }
        ' > "$hfile" || true
        log_ts "if=$ifc hostapd_cli all_sta done"
        cnt=$(wc -l < "$hfile" 2>/dev/null || echo 0)
        log_ts "if=$ifc sta_count=$cnt"

        # Skip expensive iw dump when no stations are present on this iface
        if [ ! -s "$hfile" ]; then
            log_ts "if=$ifc no stations; skip iw"
            continue
        fi

        # Parse iw station stats: choose between per-station get (IW_GET_ONLY=1) or dump with fallback
        ifile="$BASE_DIR/${ifc}_iw.tsv"
        : > "$ifile"
        if [ "${USE_IW:-0}" = "1" ]; then
            if [ "${IW_GET_ONLY:-0}" = "1" ]; then
                log_ts "if=$ifc iw station get (direct)"
                while IFS="$(printf '\t')" read -r mac _sig _txp; do
                    [ -z "$mac" ] && continue
                    process_station_iw "$ifc" "$mac" "$ts" "$ifile"
                done < "$hfile"
            else
                log_ts "if=$ifc iw station dump start"
                tmp_iw="$BASE_DIR/${ifc}_iw.$$.tsv"
                $IW_BIN dev "$ifc" station dump 2>/dev/null | awk 'BEGIN{mac="";tr="";tf="";txb="";rxb=""}
                    /^Station /{ if(mac!=""){printf "%s\t%s\t%s\t%s\t%s\n", tolower(mac), txb, rxb, tr, tf} ; split($0,a," "); mac=a[2]; tr=""; tf=""; txb=""; rxb=""; next }
                    /tx retries/{split($0,a,":"); gsub(/[^0-9]/, "", a[2]); tr=a[2]; next}
                    /tx failed/{split($0,a,":"); gsub(/[^0-9]/, "", a[2]); tf=a[2]; next}
                    /tx bytes/{split($0,a,":"); gsub(/[^0-9]/, "", a[2]); txb=a[2]; next}
                    /rx bytes/{split($0,a,":"); gsub(/[^0-9]/, "", a[2]); rxb=a[2]; next}
                    END{ if(mac!=""){printf "%s\t%s\t%s\t%s\t%s\n", tolower(mac), txb, rxb, tr, tf} }
                ' > "$tmp_iw" || true
                if [ -s "$tmp_iw" ]; then mv -f "$tmp_iw" "$ifile"; else rm -f "$tmp_iw"; fi
                log_ts "if=$ifc iw station dump done"
                if [ ! -s "$ifile" ]; then
                    log_ts "if=$ifc iw dump empty; fallback per-station get"
                    : > "$ifile"
                    while IFS="$(printf '\t')" read -r mac _sig _txp; do
                        [ -z "$mac" ] && continue
                        process_station_iw "$ifc" "$mac" "$ts" "$ifile"
                    done < "$hfile"
                fi
            fi
        fi

        # Merge the two sets keyed by MAC, then augment with hostname; append rows
        log_ts "if=$ifc merge begin"
        awk -v band="$band" -v ssid="$ssid" -v ts="$ts" -v mapfile="$MFILE" -v iface="$ifc" 'BEGIN{FS="\t";OFS="\t"}
            FNR==NR{seen[$1]=1; sig[$1]=$2; txp[$1]=$3; next}
            {
                mac=$1; n=NF;
                if (n>=3) { tr[mac]=$(n-1); tf[mac]=$(n) } else { tr[mac]=""; tf[mac]="" }
                seen[mac]=1
            }
            END{
                # Load hostname map
                if (mapfile!="" ) {
                    while( (getline line < mapfile) > 0 ){
                        split(line, m, FS); h[m[1]]=m[2]
                    }
                    close(mapfile)
                }
                for (m in seen) {
                    s=sig[m]; if(s=="") s=0
                    p=txp[m]; if(p=="") p=0
                    r=tr[m];  if(r=="") r=0
                    f=tf[m];  if(f=="") f=0
                    hh=h[m]; if(hh=="") hh="-"
                    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", band, ssid, m, hh, s, p, r, f, ts, iface
                }
            }
        ' "$hfile" "$ifile" >> "$TEMP_RAW" || true
        log_ts "if=$ifc merge end"
    done
    # Deduplicate across interfaces atomically: keep the row with strongest signal per MAC
    TEMP_CUR="$BASE_DIR/cur.$$.tsv"
    : > "$TEMP_CUR"
    awk 'BEGIN{FS="\t"}
        {
          mac=$3; sig=$5+0
          if(!(mac in best) || sig>best[mac]){ best[mac]=sig; row[mac]=$0 }
        }
        END{ for (m in row) print row[m] }
    ' "$TEMP_RAW" >> "$TEMP_CUR" 2>/dev/null || true
    rawc=$(wc -l < "$TEMP_RAW" 2>/dev/null || echo 0)
    dedupc=$(wc -l < "$TEMP_CUR" 2>/dev/null || echo 0)
    log_ts "dedup: raw_rows=$rawc kept_rows=$dedupc"
    # Guard: if dedup unexpectedly removes most rows (e.g., bad fields), fallback to raw
    if [ "$dedupc" -le 2 ] && [ "$rawc" -gt 0 ]; then
        log_ts "dedup anomaly: using raw snapshot"
        cp -f "$TEMP_RAW" "$TEMP_CUR" 2>/dev/null || true
    fi
    # Publish snapshot atomically; discard raw
    mv -f "$TEMP_CUR" "$STATE_CUR" 2>/dev/null || true
    sync 2>/dev/null || true
    rm -f "$TEMP_RAW" 2>/dev/null || true
    # Update per-MAC bytes history moved into iw per-station loop above to reuse the same iw call when P5_ENABLE=1
    # Update per-MAC history for rolling window
    mkdir -p "$WINDOW_DIR" 2>/dev/null || true
    awk -v wdir="$WINDOW_DIR" 'BEGIN{FS="\t"}
        {
          mac=$3; ts=$9; txp=$6; txr=$7; txf=$8;
          fn=wdir "/" mac ".hist";
          printf "%s %s %s %s\n", ts, txp, txr, txf >> fn
        }
    ' "$STATE_CUR" 2>/dev/null || true
    # Prune history using the current snapshot ts to avoid skew
    snap_ts=$(awk -F '\t' 'NR==1{print $9; exit}' "$STATE_CUR" 2>/dev/null || echo 0)
    if [ -z "$snap_ts" ] || [ "$snap_ts" -le 0 ]; then snap_ts=$(date +%s); fi
    cutoff=$((snap_ts - RETRY_WINDOW_SEC - 5))
    for hf in "$WINDOW_DIR"/*.hist; do
        [ -f "$hf" ] || continue
        awk -v c="$cutoff" '$1>=c' "$hf" > "${hf}.new" 2>/dev/null || true
        mv -f "${hf}.new" "$hf" 2>/dev/null || true
    done
}

print_report() {
    # Read prev and current snapshots; compute deltas and ratios
    # Main awk block computes:
    # - Per-interval deltas (d_tx, d_r, d_f) and retry ratio
    # - Rolling window TxRetry% over RETRY_WINDOW_SEC from window/<mac>.hist
    # - Throughput p5 (5th percentile) from bytes/<mac>.hist
    # - SNR from band noise map
    # - Formats output and sorts by SNR desc (fallback to signal)
    printf '\033[1m%-7s %-12s %-22s %-18s %-15s %-17s %10s %6s %7s %7s %9s %6s %11s %11s\033[0m\033[K\n' \
        "band" "ssid" "dnsname" "hostname" "ip" "mac" "d_tx" "d_r" "d_TxR%" "TxR%" "sig" "snr" "UL_p5" "DL_p5"
    date_hms=$(date +%H:%M:%S)
    awk -v now_hms="$date_hms" -v hide="$HIDE_IDLE" -v wdir="$WINDOW_DIR" -v prevfn="$STATE_PREV" -v win_secs="$RETRY_WINDOW_SEC" -v dbg="${DEBUG_WIN:-0}" -v dbgfile="$BASE_DIR/win_dbg.txt" -v hilites="$HILITE_HOSTS" -v hilitedns="$HILITE_DNS" -v win_partial="$WIN_PARTIAL" -v win_formula="$WIN_FORMULA" -v noisefn="$NOISE_FILE" -v bdir="$BYTES_DIR" -v dnsfn="$DNS_MAP_FILE" -v ipfn="$IP_MAP_FILE" -v idebug="${DEBUG_INTERVAL:-0}" -v idbgfile="$BASE_DIR/interval_dbg.txt" 'BEGIN{FS="\t"; OFS="\t";
            # Load auxiliary maps: noise per band, DNS names, IP addresses
            if (noisefn!="") { while ( (getline nl < noisefn) > 0 ) { split(nl, nn, FS); if (nn[1]!="") noise[nn[1]]=nn[2]+0 } close(noisefn) }
            if (dnsfn!="") { while ( (getline dl < dnsfn) > 0 ) { split(dl, dd, FS); if (dd[1]!="") dns[dd[1]]=dd[2] } close(dnsfn) }
            if (ipfn!="") { while ( (getline il < ipfn) > 0 ) { split(il, ii, FS); if (ii[1]!="") ipm[ii[1]]=ii[2] } close(ipfn) }
            # Build highlight set from comma-separated list
            nh=split(hilites, hh, ","); for (i=1;i<=nh;i++){ gsub(/^\s+|\s+$/, "", hh[i]); if (hh[i]!="") HL[hh[i]]=1 }
            nd=split(hilitedns, hd, ","); for (i=1;i<=nd;i++){ gsub(/^\s+|\s+$/, "", hd[i]); if (hd[i]!="") HLDNS[hd[i]]=1 }
        }
        (FILENAME==prevfn){ prev[$3]=$0; next }
        {
            key=$3
            if(!(key in prev)) next
            split(prev[key],p,FS)
            # Fields: 1=band 2=ssid 3=mac 4=host 5=signal 6=txp 7=txr 8=txf 9=ts
            dtx=$6-p[6]
            dr=$7-p[7]
            df=$8-p[8]
            if(dtx<0||dr<0||df<0) next
            if(hide=="1" && dtx==0) next
            a1=dtx; a2=dtx+df
            r1=(a1>0)?(dr*100.0/a1):0
            r2=(a2>0)?(dr*100.0/a2):0
            if ((idebug+0)>0) {
                # Log per-interval packet deltas and computed ratio
                printf("%s\tmac=%s\td_tx=%d\td_r=%d\td_f=%d\tr/(tx+f)=%.4f%%\n", now_hms, key, dtx, dr, df, r2) >> idbgfile
            }
            # Per-MAC rolling window: compute against baseline within trailing window
            # Default to per-interval retry ratio as a safe fallback; override if history is available
            hist=wdir "/" key ".hist"; winp_val=r2; denom=0; wtx=0; wr=0; wf=0;
            # Use snapshot ts from prev row to align timebase
            snap_ts=$9+0
            cutoff=snap_ts-win_secs
            bt=-1; btxp=0; btxr=0; btxf=0
            ft=-1; ftxp=0; ftxr=0; ftxf=0
            while ( (getline line < hist) > 0 ) {
                split(line, hh, " ")
                ts=hh[1]+0
                if (ft<0) { ft=ts; ftxp=hh[2]+0; ftxr=hh[3]+0; ftxf=hh[4]+0 }
                if (ts <= cutoff) { bt=ts; btxp=hh[2]+0; btxr=hh[3]+0; btxf=hh[4]+0; continue }
                # first record after cutoff; stop scanning
                break
            }
            close(hist)
            if (ft>0) {
                # Choose baseline: prefer last <= cutoff else earliest kept
                if (bt>0) { bpx=btxp; brx=btxr; bfx=btxf } else { bpx=ftxp; brx=ftxr; bfx=ftxf }
                wtx=$6-bpx; if (wtx<0) wtx=0;
                wr=$7-brx;  if (wr<0)  wr=0;
                wf=$8-bfx;  if (wf<0)  wf=0;
                # Window denominator selection
                if (win_formula=="r1") { denom=wtx }
                else if (win_formula=="r3") { denom=wtx+wf+wr }
                else { denom=wtx+wf }
                if (denom>0) { winp_val=wr*100.0/denom } else { winp_val=0 }
            }
            # Gate display until full window has elapsed: blank until age >= win_secs and denom>0
            age = (ft>0)? (snap_ts - ft) : 0;
            if ((win_partial+0)==1) {
                ready = 1;
                win_str = sprintf("%.1f%%", winp_val);
            } else {
                ready = (age>=win_secs && denom>0) ? 1 : 0;
                win_str = (ready ? sprintf("%.1f%%", winp_val) : "");
            }
            if (dbg+0>0) {
                printf("%s\t%s\tft=%d bt=%d snap=%d wtx=%d wr=%d wf=%d denom=%d win=%.2f age=%d ready=%d\n", now_hms, key, ft, bt, snap_ts, wtx, wr, wf, denom, winp_val, age, ready) >> dbgfile
            }
            snr_str=""; if (($1 in noise) && noise[$1] <= -40) { snr_val=$5 - noise[$1]; snr_str = sprintf("%d", snr_val) }
            # Compute UL/DL p5 from bytes history (approximate as 2nd-smallest 1s throughput in window)
            ul_p5_str=""; dl_p5_str="";
            bfile=bdir "/" key ".hist";
            prev_t=-1; prev_txb=0; prev_rxb=0; ul_min1=1e12; ul_min2=1e12; dl_min1=1e12; dl_min2=1e12; rc=0;
            while ( (getline bl < bfile) > 0 ) {
                split(bl, bb, " ");
                tsb=bb[1]+0; txb=bb[2]+0; rxb=bb[3]+0;
                if (prev_t<0) { prev_t=tsb; prev_txb=txb; prev_rxb=rxb; continue }
                if (tsb < cutoff) { prev_t=tsb; prev_txb=txb; prev_rxb=rxb; continue }
                dt=tsb - prev_t; if (dt<=0) { prev_t=tsb; prev_txb=txb; prev_rxb=rxb; continue }
                dtx=txb - prev_txb; drx=rxb - prev_rxb; if (dtx<0) dtx=0; if (drx<0) drx=0;
                ul_kBs = (drx)/(dt*1024.0);
                dl_kBs = (dtx)/(dt*1024.0);
                # track two smallest values
                if (ul_kBs < ul_min1) { ul_min2=ul_min1; ul_min1=ul_kBs } else if (ul_kBs < ul_min2) { ul_min2=ul_kBs }
                if (dl_kBs < dl_min1) { dl_min2=dl_min1; dl_min1=dl_kBs } else if (dl_kBs < dl_min2) { dl_min2=dl_kBs }
                rc++;
                prev_t=tsb; prev_txb=txb; prev_rxb=rxb;
            }
            close(bfile)
            if (rc>1) { ul_p5_str=sprintf("%d KB/s", int(ul_min2+0.5)); dl_p5_str=sprintf("%d KB/s", int(dl_min2+0.5)) }
            else if (rc==1) { ul_p5_str=sprintf("%d KB/s", int(ul_min1+0.5)); dl_p5_str=sprintf("%d KB/s", int(dl_min1+0.5)) }
            # Gate UL/DL p5 display the same as TxRetry%: blank until full window unless WIN_PARTIAL=1
            if ((win_partial+0)!=1 && ready==0) { ul_p5_str=""; dl_p5_str="" }
            # Build display strings with units for sig and SNR
            sig_out = sprintf("%d dBm", $5)
            snr_out = (snr_str!="" ? snr_str " dB" : "")
            dns_out = ((key in dns) ? dns[key] : "-")
            ip_out  = ((key in ipm) ? ipm[key]  : "-")
            # Prepend numeric key so we can do a reliable numeric descending sort.
            # Prefer SNR when available; fallback to signal when noise unknown.
            if (snr_str!="") { sortkey=snr_val } else { sortkey=$5 }
            # Shift to positive range to preserve numeric sort with negative values
            keynum=10000+sortkey
            # If a hostname highlight was requested, wrap that row in bold
            if ($4 in HL || (dns_out in HLDNS)) {
                pre="\033[1m"; post="\033[0m"
            } else { pre=""; post="" }
            line = sprintf("%s%-7s %-12s %-22s %-18s %-15s %-17s %10d %6d %7.1f%% %7s %9s %6s %11s %11s%s",
                            pre, $1, $2, dns_out, ($4==""?"-":$4), ip_out, $3, dtx, dr, r2, win_str, sig_out, snr_out, ul_p5_str, dl_p5_str, post)
            printf "%05d|%s\033[K\n", keynum, line
        }' "$STATE_PREV" "$STATE_CUR" |
    tee "$BASE_DIR/ui_pre.tsv" |
    sort -n -r -k1,1 |
    cut -d '|' -f2- |
    tee "$BASE_DIR/ui_core.tsv"
    # After painting rows, if the previous frame had more lines, print extra blank clears to erase leftovers
    rows=$(wc -l < "$BASE_DIR/ui_core.tsv" 2>/dev/null || echo 0)
    new_total=$((rows + 3))
    prev_total=0
    [ -s "$UI_COUNT_FILE" ] && prev_total=$(cat "$UI_COUNT_FILE" 2>/dev/null || echo 0)
    if [ "$prev_total" -gt "$new_total" ]; then
        n=$((prev_total - new_total))
        i=0
        while [ "$i" -lt "$n" ]; do
            printf "\033[K\n"
            i=$((i+1))
        done
    fi
    # Add blank line and timestamp at the bottom
    printf "\033[K\n"
    printf "last updated: %s\033[K\n" "$date_hms"
    echo "$new_total" > "$UI_COUNT_FILE" 2>/dev/null || true
}

# Main loop
trap cleanup INT TERM EXIT
reset_volatile_state
init_ip_dns_once
while :; do
    start_hostmap_updater
    start_ms=$(now_ms)
    log_ts "collect start"
    collect_snapshot
    log_ts "collect done"
    # For the very first frame, clear the entire screen to avoid painting over prior SSH text
    if [ ! -f "$BASE_DIR/ui_lines.count" ]; then
        printf "\033[2J\033[H" 2>/dev/null || clear 2>/dev/null || printf "\033c" || true
    else
        # Subsequent frames: move cursor to home (no full clear). Each line print clears to end via ESC[K.
        printf "\033[H" 2>/dev/null || true
    fi
    if [ -s "$STATE_PREV" ] && [ -s "$STATE_CUR" ]; then
        log_ts "print_report start"
        print_report || true
        log_ts "print_report done"
    else
        printf "Priming counters... (waiting %dms for first delta)\n" "$REFRESH_MS"
        # Initialize per-MAC history directory
        mkdir -p "$WINDOW_DIR" 2>/dev/null || true
    fi
    # Keep current snapshot available for external inspection; copy to prev
    cp -f "$STATE_CUR" "$STATE_PREV" 2>/dev/null || true
    # Maintain target cadence by subtracting time spent collecting/printing
    end_ms=$(now_ms)
    elapsed=$((end_ms - start_ms))
    wait_ms=$((REFRESH_MS - elapsed))
    if [ "$wait_ms" -lt 1 ]; then wait_ms=1; fi
    log_ts "sleep ${wait_ms}ms (elapsed=${elapsed}ms)"
    sleep_ms "$wait_ms"
    
done
