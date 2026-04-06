#!/bin/sh
set -eu

# u6e-scanner — real-time per-client WiFi monitor for Ubiquiti U6 Enterprise
#
# Displays one row per connected client, updated every REFRESH_MS, showing:
#   band, ssid, dnsname, hostname, ip, [mac], d_tx, d_r, d_txr%, txr%-N, sig, snr, TxRate, RxRate
#
# Verified on firmware 6.8.2 (LEDE 17.01, BusyBox ash, Qualcomm IPQ50xx armv7l).

# ─── DATA SOURCES ────────────────────────────────────────────────────────────
#
# Every refresh (main loop, all ifaces queried in parallel):
#   hostapd_cli all_sta       → signal (dBm), tx_packets (cumulative); one batch call per iface
#   wlanconfig list sta       → negotiated TxRate (AP→client) and RxRate (client→AP) in Mbps;
#                               one batch call per iface. "iw" does NOT report bitrate on this
#                               firmware; wlanconfig is the only reliable source.
#
# Every NOISE_CACHE_SEC (noise background loop):
#   iwconfig                  → noise floor per iface (for SNR); averaged per band into noise.tsv
#
# Every IW_CACHE_SEC (fast background loop):
#   iw station get <mac>      → tx_retries, tx_failed; one call per client, run in background
#                               so iw latency does not block the main refresh loop.
#                               "iw station dump" is non-functional on this firmware; per-station
#                               "iw station get" is used instead (IW_GET_ONLY=1).
#
# Every HOST_CACHE_SEC (slow background loop):
#   mca-dump sta_table        → hostname per MAC; merged with display_name/device_name fallbacks
#   mca-dump sta_table        → IP per MAC; merged into ipmap.tsv
#   nslookup <ip>             → reverse DNS (dnsname); looked up once per MAC, then cached
#   hostapd_cli get_config    → SSID per iface (also called once synchronously at startup)
#   iw dev + hostapd_cli      → active AP ifaces with clients (when IFACES=auto)

# ─── TIMERS AND CONTROL FLOW ─────────────────────────────────────────────────
#
# Startup (before main loop):
#   1. reset_volatile_state   — clear snapshot files, window history, and per-run caches
#   2. bootstrap_from_arp     — background: ARP table → nslookup per IP → hostnames.tsv,
#                               written one hostname at a time as discovered (~50ms each).
#                               Skipped if hostnames.tsv already has data from prior run.
#                               mca-dump data overwrites this when background loop finishes.
#   3. build_ssid_map         — populate ssid.tsv immediately so first frame shows SSIDs
#   4. start_hostmap_updater  — launch slow background loop (HOST_CACHE_SEC)
#   5. start_iw_updater       — launch fast background loop (IW_CACHE_SEC)
#   6. start_noise_updater    — launch noise floor background loop (NOISE_CACHE_SEC)
#
# Main loop (every REFRESH_MS; PRIME_MS on the first cycle):
#   Phase 1 (parallel): for all active AP ifaces simultaneously, and within each iface
#     wlanconfig and hostapd_cli also run in parallel with each other:
#     - wlanconfig list sta → <iface>_rates.tsv (TxRate/RxRate per MAC) [atomic write]
#     - hostapd_cli all_sta → <iface>_hostapd.tsv (signal, tx_packets per MAC) [atomic write]
#   Phase 2 (serial merge): for each iface:
#     - read cached <iface>_iw.tsv (written by iw background loop) [no subprocess]
#     - merge all three by MAC, attach hostname from hostnames.tsv → cur_raw.tsv
#   Deduplicate by MAC across ifaces keeping strongest signal → cur.tsv (atomic)
#   Append window/<mac>.hist (ts, tx_packets, tx_retries, tx_failed)
#   Refresh noise map if older than NOISE_CACHE_SEC
#   Render UI: compute deltas, retry%, SNR, sort by SNR desc
#
# iw background loop (every IW_CACHE_SEC=2s, detached):
#   For each active iface with clients (reads <iface>_hostapd.tsv for MAC list):
#     - iw station get per client → <iface>_iw.tsv (atomic write)
#   Decoupled from main loop so iw latency (~100-200ms per client) does not block refreshes.
#
# Slow background loop (every HOST_CACHE_SEC=60s, detached):
#   rebuild_hostname_map:
#     - one mca-dump call, reused for all of the following:
#     - parse sta_table for (mac, hostname); second pass for display_name/device_name fallbacks
#     - merge and write hostnames.tsv atomically (overwrites bootstrap)
#     - extract (mac, ip) from sta_table; merge into ipmap.tsv (persistent)
#     - for each MAC/IP not yet in dnsnames.tsv: nslookup → dnsnames.tsv (persistent, never re-queried)
#   compute_active_ifaces (if IFACES=auto)
#   build_ssid_map
#   prune window/<mac>.hist files beyond RETRY_WINDOW_SEC

# ─── CACHED FILES (/tmp/u6e-scanner) ─────────────────────────────────────────
#
# Volatile — cleared on startup, rebuilt each run:
#   cur.tsv, prev.tsv         snapshot pairs for delta computation
#                             schema: band, ssid, mac, hostname, signal, tx_packets,
#                                     tx_retries, tx_failed, ts, iface, rxrate, txrate
#   <iface>_hostapd.tsv       per-iface hostapd_cli parse (mac, signal, tx_packets)
#   <iface>_iw.tsv            per-iface iw parse (mac, tx_retries, tx_failed)
#   <iface>_rates.tsv         per-iface wlanconfig parse (mac, txrate, rxrate)
#   window/<mac>.hist         rolling window counters: "ts tx_packets tx_retries tx_failed"
#   noise.tsv                 per-band noise floor: "band<TAB>noise_dBm"
#   ssid.tsv                  iface→SSID map
#   ifaces.txt                active AP ifaces with clients (IFACES=auto)
#   band_cache.tsv            iface→band map (2.4GHz/5GHz/6GHz)
#
# Persistent — survive restarts, serve as initial display cache:
#   hostnames.tsv             mac→hostname (from mca-dump)
#   ipmap.tsv                 mac→ip (from mca-dump sta_table)
#   dnsnames.tsv              mac→dnsname (from nslookup PTR; never re-queried once present)
#
# All persistent files are refreshed by the background updater while running.
# Volatile files are always cleared at startup to prevent stale deltas.

# ─── COLUMNS ─────────────────────────────────────────────────────────────────
#
#   band      2.4GHz / 5GHz / 6GHz
#   ssid      network name (from hostapd_cli get_config)
#   dnsname   reverse DNS name (PTR lookup via nslookup; ".lan" suffix stripped)
#   hostname  device hostname from mca-dump sta_table
#   ip        IP address from mca-dump sta_table
#   [mac]     MAC address (shown only with -m flag)
#   d_tx      tx_packets delta since last refresh (packet count, not bytes)
#   d_r       tx_retries delta since last refresh
#   d_txr%    per-interval retry ratio: d_r / (d_tx + d_failed) × 100
#   txr%-N    rolling retry% over N seconds (RETRY_WINDOW_SEC; blank until full window)
#   sig       RSSI in dBm
#   snr       signal - per-band noise floor in dB (blank if noise unknown or > -40 dBm)
#   TxRate    negotiated downlink rate AP→client in Mbps (from wlanconfig)
#   RxRate    negotiated uplink rate client→AP in Mbps (from wlanconfig)
#
# Rows sorted by SNR desc; falls back to signal desc when noise is unknown.
# Rows deduped by MAC across radios, keeping the entry with the strongest signal.

# ─── CLI FLAGS ───────────────────────────────────────────────────────────────
#
#   -m                 show mac column (hidden by default)
#   -h <name>          bold rows whose hostname exactly matches <name> (repeatable)
#   -d <name>          bold rows whose dnsname exactly matches <name> (repeatable)
#   -n <substr>        bold rows where <substr> appears anywhere in hostname or dnsname
#   -o <substr>        show only rows where <substr> appears in hostname or dnsname (repeatable; implies bold)

# ─── ENV VARS ────────────────────────────────────────────────────────────────
#
#   REFRESH_MS=1000        main loop cadence in ms (first cycle uses PRIME_MS)
#   PRIME_MS=500           sleep after first snapshot before showing initial table
#   IW_CACHE_SEC=2         iw background loop period (retries/failed refresh)
#   HOST_CACHE_SEC=60      slow background loop period (hostname/DNS/SSID/iface refresh)
#   NOISE_CACHE_SEC=10     noise floor background loop period in seconds
#   RETRY_WINDOW_SEC=30    rolling window length for txr%
#   WIN_FORMULA=r2         retry% denominator: r1=tx, r2=tx+failed, r3=tx+failed+retries
#   WIN_PARTIAL=0          0=blank txr% until full window elapsed; 1=show partial immediately
#   WIN_MIN_PKTS=10        minimum tx_packets in window required to display txr%-N
#   IFACES=auto            "auto" discovers active AP ifaces; or space-separated list
#   USE_IW=1               1=use iw background loop for retries/failed; 0=skip
#   IW_GET_ONLY=1          1=per-station iw get only (skip iw dump, unreliable on this fw)
#   HIDE_IDLE=0            1=hide rows with d_tx=0 in last interval
#   NICE_BG=1              1=run external commands with nice -n 15
#   DNSNAME_ENABLE=1       1=run reverse DNS lookups for dnsname column
#   TIMERS=0               1=write debug timestamps to stderr and debug.log
#   DEBUG_WIN=0            1=write rolling window diagnostics to win_dbg.txt
#   DEBUG_INTERVAL=0       1=write per-interval delta diagnostics to interval_dbg.txt

# ─── FIRMWARE NOTES ──────────────────────────────────────────────────────────
#
#   Firmware <=6.6.x: AP interfaces named ath* (e.g., ath4, ath5)
#   Firmware >=6.7.x: AP interfaces named wifi*ap* (e.g., wifi0ap0, wifi1ap3)
#   Both naming schemes are supported; dumtxvap* and other non-AP ifaces are excluded.
#   usleep unavailable on >=6.7.x; sleep_ms falls back to whole-second sleep.
#   BusyBox nslookup PTR output: Name: line precedes Address line with the hostname.
#   All TSV reads use IFS="$(printf '\t')" for correct tab splitting under BusyBox ash.

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
NOISE_FILE="$BASE_DIR/noise.tsv"
UI_COUNT_FILE="$BASE_DIR/ui_lines.count"
DNS_MAP_FILE="$BASE_DIR/dnsnames.tsv"
IP_MAP_FILE="$BASE_DIR/ipmap.tsv"
BAND_CACHE_FILE="$BASE_DIR/band_cache.tsv"
NOISE_LAST_UPDATE_FILE="$BASE_DIR/noise.lastupdate"
REFRESH_MS="${REFRESH_MS:-1000}"
PRIME_MS="${PRIME_MS:-500}"
NOISE_CACHE_SEC="${NOISE_CACHE_SEC:-10}"
HIDE_IDLE="${HIDE_IDLE:-0}"
HOST_CACHE_SEC="${HOST_CACHE_SEC:-60}"
TIMERS="${TIMERS:-0}"
IFACES="${IFACES:-auto}"
RETRY_WINDOW_SEC="${RETRY_WINDOW_SEC:-30}"
MCA_DUMP_BIN_RAW="${MCA_DUMP_BIN_RAW:-$(command -v mca-dump 2>/dev/null || echo /usr/bin/mca-dump)}"
IW_BIN_RAW="${IW_BIN_RAW:-$(command -v iw 2>/dev/null || echo /usr/sbin/iw)}"
HOSTAPD_CLI_BIN_RAW="${HOSTAPD_CLI_BIN_RAW:-$(command -v hostapd_cli 2>/dev/null || echo /usr/sbin/hostapd_cli)}"
WLANCONFIG_BIN_RAW="${WLANCONFIG_BIN_RAW:-$(command -v wlanconfig 2>/dev/null || echo /usr/sbin/wlanconfig)}"
NICE_BG="${NICE_BG:-1}"
if [ "${NICE_BG}" = "1" ]; then
    NICE_PREFIX="nice -n 15 "
else
    NICE_PREFIX=""
fi
MCA_DUMP_BIN="${NICE_PREFIX}${MCA_DUMP_BIN_RAW}"
IW_BIN="${NICE_PREFIX}${IW_BIN_RAW}"
HOSTAPD_CLI_BIN="${NICE_PREFIX}${HOSTAPD_CLI_BIN_RAW}"
WLANCONFIG_BIN="${NICE_PREFIX}${WLANCONFIG_BIN_RAW}"
NSLOOKUP_BIN_RAW="${NSLOOKUP_BIN_RAW:-$(command -v nslookup 2>/dev/null || echo /usr/bin/nslookup)}"
NSLOOKUP_BIN="${NSLOOKUP_BIN_RAW}"
DBG_LOG="$BASE_DIR/debug.log"
USE_IW="${USE_IW:-1}"
IW_GET_ONLY="${IW_GET_ONLY:-1}"
IW_CACHE_SEC="${IW_CACHE_SEC:-2}"
WIN_PARTIAL="${WIN_PARTIAL:-0}"
WIN_MIN_PKTS="${WIN_MIN_PKTS:-10}"
WIN_FORMULA="${WIN_FORMULA:-r2}"
DNSNAME_ENABLE="${DNSNAME_ENABLE:-1}"
DEBUG_INTERVAL="${DEBUG_INTERVAL:-0}"
IW_PID_FILE="$BASE_DIR/iw_updater.pid"
NOISE_PID_FILE="$BASE_DIR/noise_updater.pid"

# Detect best sub-second sleep method once at startup to avoid fork-per-sleep
if command -v usleep >/dev/null 2>&1; then
    _SLEEP_METHOD="usleep"
elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx usleep; then
    _SLEEP_METHOD="busybox_usleep"
elif sleep 0.001 2>/dev/null; then
    _SLEEP_METHOD="fractional"
else
    _SLEEP_METHOD="whole"
fi

bootstrap_from_arp() {
    # Quick hostname bootstrap: ARP table gives MAC→IP instantly; nslookup gives
    # IP→hostname (~50ms each). Writes each hostname to hostnames.tsv immediately
    # as it's discovered, so names appear in the UI one by one rather than all at
    # once. Skipped if hostnames.tsv already has data from a prior run.
    # mca-dump data overwrites this when the slow background loop finishes.
    [ -s "$MAP_FILE" ] && return 0
    [ -f /proc/net/arp ] || return 0
    ns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
    : > "$MAP_FILE"
    # /proc/net/arp: IP HW_type Flags MAC Mask Device (skip header, skip incomplete)
    awk 'NR>1 && $3=="0x2" && $4!="00:00:00:00:00:00" {print tolower($4) "\t" $1}' \
        /proc/net/arp 2>/dev/null | \
    while IFS="$(printf '\t')" read -r mac ip; do
        name=$($NSLOOKUP_BIN "$ip" ${ns:+"$ns"} 2>/dev/null | awk '
            /^Name:/ { in_ptr=1; next }
            in_ptr && /^Address/ { v=$NF; gsub(/\.$/, "", v); print v; exit }
        ' | head -n1)
        if [ -n "$name" ]; then
            case "$name" in *.lan) name=${name%".lan"};; esac
            printf "%s\t%s\n" "$mac" "$name" >> "$MAP_FILE" 2>/dev/null || true
        fi
    done
}

# Reset volatile state at cold start so no prior run contaminates deltas/window
reset_volatile_state() {
    # Kill stale background processes from any prior run before clearing their PID files
    for pidfile in "$PID_FILE" "$IW_PID_FILE" "$NOISE_PID_FILE"; do
        if [ -f "$pidfile" ]; then
            old_pid=$(cat "$pidfile" 2>/dev/null || true)
            [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null || true
            rm -f "$pidfile" 2>/dev/null || true
        fi
    done
    # Counters, deltas, windows — must be clean so first display is accurate
    rm -f "$BASE_DIR/prev.tsv" "$BASE_DIR/cur.tsv" 2>/dev/null || true
    rm -f "$BASE_DIR"/*_hostapd.tsv "$BASE_DIR"/*_iw.tsv "$BASE_DIR"/*_rates.tsv 2>/dev/null || true
    rm -rf "$BASE_DIR/window" 2>/dev/null || true
    rm -f "$BASE_DIR/ui_lines.count" "$BASE_DIR/noise.lastupdate" 2>/dev/null || true
    # Interface/SSID/band state — must refresh on each run in case topology changed
    rm -f "$BASE_DIR/ifaces.txt" "$BASE_DIR/ssid.tsv" "$BASE_DIR/band_cache.tsv" 2>/dev/null || true
    # Background updater flags/locks from any prior run
    rm -f "$BASE_DIR/hostmap.started" 2>/dev/null || true
    rm -rf "$BASE_DIR/hostmap.rebuild.lock" "$LOCK_DIR" 2>/dev/null || true
    # Leftover temp files from interrupted prior runs
    rm -f "$BASE_DIR"/hostnames.tsv.new.* "$BASE_DIR"/ifaces.txt.new.* 2>/dev/null || true
    # Persisted across runs (used to populate display immediately on restart):
    #   hostnames.tsv, dnsnames.tsv, ipmap.tsv — hostname/DNS/IP caches
    # These are refreshed by the background updater while running.
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

# Optional flags from CLI: -h/-d/-n/-o for row highlights/filter, -m to show mac column
HILITE_HOSTS=""
HILITE_DNS=""
HILITE_NAME=""
ONLY_NAME=""
SHOW_MAC="0"
while [ $# -gt 0 ]; do
    case "$1" in
        -h)
            shift
            if [ $# -gt 0 ]; then
                val="$1"
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
                if [ -n "$val" ]; then
                    if [ -z "$HILITE_DNS" ]; then HILITE_DNS="$val"; else HILITE_DNS="$HILITE_DNS,$val"; fi
                fi
            fi
            shift || true
            ;;
        -n)
            shift
            if [ $# -gt 0 ]; then
                val="$1"
                if [ -n "$val" ]; then
                    if [ -z "$HILITE_NAME" ]; then HILITE_NAME="$val"; else HILITE_NAME="$HILITE_NAME,$val"; fi
                fi
            fi
            shift || true
            ;;
        -o)
            shift
            if [ $# -gt 0 ]; then
                val="$1"
                if [ -n "$val" ]; then
                    if [ -z "$ONLY_NAME" ]; then ONLY_NAME="$val"; else ONLY_NAME="$ONLY_NAME,$val"; fi
                fi
            fi
            shift || true
            ;;
        -m)
            SHOW_MAC="1"
            shift
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

# Sleep helper that accepts milliseconds; uses method detected at startup
sleep_ms() {
    ms="${1:-1000}"
    case "$_SLEEP_METHOD" in
        usleep)         usleep "$((ms * 1000))" ;;
        busybox_usleep) busybox usleep "$((ms * 1000))" ;;
        fractional)     sleep "$(awk -v m="$ms" 'BEGIN{printf "%.3f", m/1000}')" 2>/dev/null || true ;;
        whole)          [ "$ms" -ge 1000 ] && sleep $(( (ms + 999) / 1000 )) || true ;;
    esac
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
        mv -f "$tmp_merged" "$MAP_FILE" 2>/dev/null || true
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
        while IFS="$(printf '\t')" read -r mm ii; do
            [ -z "$mm" ] && continue
            # Skip if already have an entry
            if grep -iq "^$mm\t" "$DNS_MAP_FILE" 2>/dev/null; then continue; fi
            [ -z "$ii" ] && continue
            if [ -n "$ns" ]; then
                name=$($NSLOOKUP_BIN "$ii" "$ns" 2>/dev/null | awk '
                    /^Name:/ { in_ptr=1; next }
                    in_ptr && /^Address/ { v=$NF; gsub(/\.$/, "", v); print v; exit }
                ' | head -n1)
            else
                name=$($NSLOOKUP_BIN "$ii" 2>/dev/null | awk '
                    /^Name:/ { in_ptr=1; next }
                    in_ptr && /^Address/ { v=$NF; gsub(/\.$/, "", v); print v; exit }
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
    # Start background loop: refresh hostnames, active ifaces, SSIDs, and window history every HOST_CACHE_SEC
    log_ts "hostmap: starting background updater"
    (
        while :; do
            rebuild_hostname_map
            [ "$IFACES" = "auto" ] && compute_active_ifaces
            build_ssid_map >/dev/null 2>&1
            # Prune window history here (infrequently) rather than in the hot main loop
            if [ -d "$WINDOW_DIR" ]; then
                cutoff=$(( $(date +%s) - RETRY_WINDOW_SEC - 5 ))
                for hf in "$WINDOW_DIR"/*.hist; do
                    [ -f "$hf" ] || continue
                    awk -v c="$cutoff" '$1>=c' "$hf" > "${hf}.new" 2>/dev/null || true
                    mv -f "${hf}.new" "$hf" 2>/dev/null || true
                done
            fi
            sleep "$HOST_CACHE_SEC" || exit 0
        done
    ) >/dev/null 2>&1 &
    echo $! > "$PID_FILE" 2>/dev/null || true
    log_ts "hostmap: updater started pid=$(cat "$PID_FILE" 2>/dev/null)"
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
    stop_iw_updater
    stop_noise_updater
    # Remove temporary/volatile files
    rm -f "$BASE_DIR"/*_hostapd.tsv "$BASE_DIR"/*_iw.tsv 2>/dev/null || true
    rm -rf "$WINDOW_DIR" 2>/dev/null || true
    rm -f "$BASE_DIR/prev.tsv" "$BASE_DIR/cur.tsv" "$BASE_DIR/band_cache.tsv" "$BASE_DIR/ui_lines.count" "$BASE_DIR/noise.lastupdate" 2>/dev/null || true
    rm -f "$BASE_DIR"/hostnames.tsv.new.* "$BASE_DIR"/ifaces.txt.new.* 2>/dev/null || true
    # Remove hostname updater locks/flags
    rm -rf "$LOCK_DIR" "$BASE_DIR/hostmap.rebuild.lock" 2>/dev/null || true
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

lookup_hostname() {
    # $1: mac, $2: map_file
    grep -i -m1 "^$1\t" "$2" 2>/dev/null | cut -f2 || true
}

build_ssid_map() {
    # Rebuild iface -> SSID map (called by background updater every HOST_CACHE_SEC)
    : > "$SSID_MAP_FILE"
    for ifc in $($IW_BIN dev 2>/dev/null | awk '$1=="Interface"{i=$2} $1=="type" && $2=="AP"{print i}' | grep -E '^(ath[0-9]+|wifi[0-9]+ap[0-9]+)$'); do
        ssid=$($HOSTAPD_CLI_BIN -i "$ifc" get_config 2>/dev/null | awk -F= '/^ssid=/{print $2; exit}') || ssid=""
        [ -z "$ssid" ] && ssid="-"
        printf "%s\t%s\n" "$ifc" "$ssid" >> "$SSID_MAP_FILE"
    done
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
    # $1=iface $2=mac $3=output_file — appends "mac tr tf" line
    local ifc="$1" mac="$2" outfile="$3"
    $IW_BIN dev "$ifc" station get "$mac" 2>/dev/null | awk -v mac="$mac" '
        BEGIN{tr=0;tf=0}
        /tx retries/{split($0,a,":"); gsub(/[^0-9]/,"",a[2]); tr=a[2]+0}
        /tx failed/{split($0,a,":"); gsub(/[^0-9]/,"",a[2]); tf=a[2]+0}
        END{printf "%s\t%s\t%s\n", mac, tr, tf}
    ' >> "$outfile" || true
}

start_iw_updater() {
    # Background loop: refresh iw retries/failed for all clients every IW_CACHE_SEC.
    # Runs independently of the main loop so iw latency doesn't block refreshes.
    [ "${USE_IW:-1}" = "1" ] || return 0
    log_ts "iw updater: starting"
    (
        while :; do
            for ifc in $(list_ap_ifaces); do
                hfile="$BASE_DIR/${ifc}_hostapd.tsv"
                [ -s "$hfile" ] || continue
                ifile="$BASE_DIR/${ifc}_iw.tsv"
                tmp_iw="${ifile}.new.$$"
                : > "$tmp_iw"
                if [ "${IW_GET_ONLY:-1}" = "1" ]; then
                    while IFS="$(printf '\t')" read -r mac _rest; do
                        [ -z "$mac" ] && continue
                        process_station_iw "$ifc" "$mac" "$tmp_iw"
                    done < "$hfile"
                else
                    $IW_BIN dev "$ifc" station dump 2>/dev/null | awk 'BEGIN{mac="";tr="";tf=""}
                        /^Station /{ if(mac!=""){printf "%s\t%s\t%s\n", tolower(mac), tr, tf}; split($0,a," "); mac=a[2]; tr=""; tf=""; next }
                        /tx retries/{split($0,a,":"); gsub(/[^0-9]/, "", a[2]); tr=a[2]; next}
                        /tx failed/{split($0,a,":"); gsub(/[^0-9]/, "", a[2]); tf=a[2]; next}
                        END{ if(mac!=""){printf "%s\t%s\t%s\n", tolower(mac), tr, tf} }
                    ' > "$tmp_iw" || true
                    if [ ! -s "$tmp_iw" ]; then
                        while IFS="$(printf '\t')" read -r mac _rest; do
                            [ -z "$mac" ] && continue
                            process_station_iw "$ifc" "$mac" "$tmp_iw"
                        done < "$hfile"
                    fi
                fi
                [ -s "$tmp_iw" ] && mv -f "$tmp_iw" "$ifile" 2>/dev/null || rm -f "$tmp_iw" 2>/dev/null || true
            done
            sleep "${IW_CACHE_SEC:-2}" || exit 0
        done
    ) >/dev/null 2>&1 &
    echo $! > "$IW_PID_FILE" 2>/dev/null || true
    log_ts "iw updater: started pid=$(cat "$IW_PID_FILE" 2>/dev/null)"
}

stop_iw_updater() {
    if [ -f "$IW_PID_FILE" ]; then
        pid=$(cat "$IW_PID_FILE" 2>/dev/null || echo 0)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
        rm -f "$IW_PID_FILE" 2>/dev/null || true
    fi
}

start_noise_updater() {
    # Background loop: refresh per-band noise floor every NOISE_CACHE_SEC.
    # Runs independently so iwconfig calls never block the main refresh loop.
    log_ts "noise updater: starting"
    (
        while :; do
            compute_noise_map >/dev/null 2>&1 || true
            sleep "${NOISE_CACHE_SEC:-10}" || exit 0
        done
    ) >/dev/null 2>&1 &
    echo $! > "$NOISE_PID_FILE" 2>/dev/null || true
    log_ts "noise updater: started pid=$(cat "$NOISE_PID_FILE" 2>/dev/null)"
}

stop_noise_updater() {
    if [ -f "$NOISE_PID_FILE" ]; then
        pid=$(cat "$NOISE_PID_FILE" 2>/dev/null || echo 0)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
        rm -f "$NOISE_PID_FILE" 2>/dev/null || true
    fi
}

collect_snapshot() {
    # Produce TSV rows atomically to avoid races: band    ssid    mac    host    signal    tx_packets    tx_retries    tx_failed    timestamp
    TEMP_RAW="$BASE_DIR/cur_raw.$$.tsv"
    : > "$TEMP_RAW"
    ts=$(date +%s)
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
    faces=$(list_ap_ifaces)
    log_ts "cycle ifaces: ${faces}"
    # Phase 1: fire off wlanconfig + hostapd_cli for all ifaces in parallel
    _collect_pids=""
    for ifc in $faces; do
        rfile="$BASE_DIR/${ifc}_rates.tsv"
        hfile="$BASE_DIR/${ifc}_hostapd.tsv"
        htmp="$BASE_DIR/${ifc}_hostapd.tsv.new.$$"
        rtmp="$BASE_DIR/${ifc}_rates.tsv.new.$$"
        log_ts "if=$ifc collection start (parallel)"
        (
            $WLANCONFIG_BIN "$ifc" list sta 2>/dev/null | awk '
                /^[0-9a-fA-F][0-9a-fA-F]:/{
                    mac=tolower($1); txrate=$4; rxrate=$5
                    gsub(/M/, "", txrate); gsub(/M/, "", rxrate)
                    printf "%s\t%s\t%s\n", mac, txrate, rxrate
                }
            ' > "$rtmp" 2>/dev/null || true
            mv -f "$rtmp" "$rfile" 2>/dev/null || true
        ) &
        _rp=$!
        (
            $HOSTAPD_CLI_BIN -i "$ifc" all_sta 2>/dev/null | awk 'BEGIN{sig="";txp="";mac=""}
                /^[0-9a-fA-F][0-9a-fA-F]:/ { if(mac!=""){printf "%s\t%s\t%s\n", tolower(mac), sig, txp} ; mac=$0; sig=""; txp=""; next }
                /^signal=/{split($0,a,"="); sig=a[2]; next}
                /^tx_packets=/{split($0,a,"="); txp=a[2]; next}
                /^$/ { if(mac!=""){printf "%s\t%s\t%s\n", tolower(mac), sig, txp} ; mac=""; sig=""; txp="" }
                END{ if(mac!=""){printf "%s\t%s\t%s\n", tolower(mac), sig, txp} }
            ' > "$htmp" 2>/dev/null || true
            mv -f "$htmp" "$hfile" 2>/dev/null || true
        ) &
        _collect_pids="$_collect_pids $_rp $!"
    done
    # Wait only for the collection jobs spawned above (not the long-running background loops)
    for _pid in $_collect_pids; do
        wait "$_pid" 2>/dev/null || true
    done
    log_ts "parallel collection done"
    # Phase 2: merge results for each iface
    for ifc in $faces; do
        band=$(get_band_from_iface "$ifc")
        ssid=$(lookup_ssid "$ifc")
        hfile="$BASE_DIR/${ifc}_hostapd.tsv"
        rfile="$BASE_DIR/${ifc}_rates.tsv"
        [ "$TIMERS" = "1" ] && log_ts "if=$ifc sta_count=$(wc -l < "$hfile" 2>/dev/null || echo 0)"

        # Skip merge when no stations are present on this iface
        if [ ! -s "$hfile" ]; then
            log_ts "if=$ifc no stations; skip merge"
            continue
        fi

        # iw retries/failed written by background iw_updater loop; read cached file
        ifile="$BASE_DIR/${ifc}_iw.tsv"
        [ -f "$ifile" ] || : > "$ifile"

        # Merge hostapd + iw by MAC, augment with hostname; append rows
        log_ts "if=$ifc merge begin"
        awk -v band="$band" -v ssid="$ssid" -v ts="$ts" -v mapfile="$MFILE" -v iface="$ifc" -v ratesfile="$rfile" 'BEGIN{FS="\t";OFS="\t"
            # Load wlanconfig rates map: mac -> txrate (AP→client), rxrate (client→AP)
            if (ratesfile!="") {
                while ((getline rl < ratesfile) > 0) {
                    split(rl, rr, FS); if (rr[1]!="") { txrate_map[rr[1]]=rr[2]; rxrate_map[rr[1]]=rr[3] }
                }
                close(ratesfile)
            }
        }
            FNR==NR{seen[$1]=1; sig[$1]=$2; txp[$1]=$3; next}
            {
                mac=$1; tr[mac]=$2; tf[mac]=$3; seen[mac]=1
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
                    r=tr[m];  if(r=="") r=-1
                    f=tf[m];  if(f=="") f=-1
                    hh=h[m]; if(hh=="") hh="-"
                    rt=(m in txrate_map ? txrate_map[m] : "-")
                    rr=(m in rxrate_map ? rxrate_map[m] : "-")
                    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", band, ssid, m, hh, s, p, r, f, ts, iface, rr, rt
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
    rm -f "$TEMP_RAW" 2>/dev/null || true
    # Update per-MAC history for rolling window.
    # Store per-cycle DELTAS (not cumulative values) so the window sum is a simple
    # sum over records in the window — no baseline-crossing artifact from iw caching.
    mkdir -p "$WINDOW_DIR" 2>/dev/null || true
    awk -v wdir="$WINDOW_DIR" 'BEGIN{FS="\t"}
        FNR==NR{
            if ($7+0 < 0 || $8+0 < 0) next  # prev had iw sentinel; mark invalid
            ppkt[$3]=$6+0; prtr[$3]=$7+0; pfail[$3]=$8+0; next
        }
        {
            if ($7+0 < 0 || $8+0 < 0) next  # cur has iw sentinel; skip
            mac=$3
            if (!(mac in ppkt)) next  # no valid prev record for this MAC
            dpkt  = $6 - ppkt[mac]; if (dpkt  < 0) dpkt  = 0
            drtr  = $7 - prtr[mac]; if (drtr  < 0) drtr  = 0
            dfail = $8 - pfail[mac]; if (dfail < 0) dfail = 0
            printf "%s %s %s %s\n", $9, dpkt, drtr, dfail >> wdir "/" mac ".hist"
        }
    ' "$STATE_PREV" "$STATE_CUR" 2>/dev/null || true
    # History pruning is handled by the slow background loop (start_hostmap_updater)
    # to avoid spawning N awk processes per refresh cycle.
}

print_report() {
    # Read prev and current snapshots; compute deltas and ratios
    # Main awk block computes:
    # - Per-interval deltas (d_tx, d_r, d_f) and retry ratio
    # - Rolling window TxRetry% over RETRY_WINDOW_SEC from window/<mac>.hist
    # - Throughput p5 (5th percentile) from bytes/<mac>.hist
    # - SNR from band noise map
    # - Formats output and sorts by SNR desc (fallback to signal)
    if [ "$SHOW_MAC" = "1" ]; then
        printf '\033[1m%-7s %-12s %-22s %-20s %-15s %17s %5s %6s %8s   %7s %9s %6s  %9s %9s\033[0m\033[K\n' \
            "band" "ssid" "dnsname" "hostname" "ip" "mac" "d_tx" "d_r" "d_txr%" "txr%-${RETRY_WINDOW_SEC}" "sig" "snr" "TxRate" "RxRate"
    else
        printf '\033[1m%-7s %-12s %-22s %-20s %-15s %5s %6s %8s   %7s %9s %6s  %9s %9s\033[0m\033[K\n' \
            "band" "ssid" "dnsname" "hostname" "ip" "d_tx" "d_r" "d_txr%" "txr%-${RETRY_WINDOW_SEC}" "sig" "snr" "TxRate" "RxRate"
    fi
    date_hms=$(date +%H:%M:%S)
    awk -v now_hms="$date_hms" -v hide="$HIDE_IDLE" -v wdir="$WINDOW_DIR" -v prevfn="$STATE_PREV" -v win_secs="$RETRY_WINDOW_SEC" -v dbg="${DEBUG_WIN:-0}" -v dbgfile="$BASE_DIR/win_dbg.txt" -v hilites="$HILITE_HOSTS" -v hilitedns="$HILITE_DNS" -v hilitename="$HILITE_NAME" -v onlyname="$ONLY_NAME" -v win_partial="$WIN_PARTIAL" -v win_formula="$WIN_FORMULA" -v win_min_pkts="$WIN_MIN_PKTS" -v noisefn="$NOISE_FILE" -v dnsfn="$DNS_MAP_FILE" -v ipfn="$IP_MAP_FILE" -v idebug="${DEBUG_INTERVAL:-0}" -v idbgfile="$BASE_DIR/interval_dbg.txt" -v show_mac="$SHOW_MAC" 'BEGIN{FS="\t"; OFS="\t";
            # Load auxiliary maps: noise per band, DNS names, IP addresses
            if (noisefn!="") { while ( (getline nl < noisefn) > 0 ) { split(nl, nn, FS); if (nn[1]!="") noise[nn[1]]=nn[2]+0 } close(noisefn) }
            if (dnsfn!="") { while ( (getline dl < dnsfn) > 0 ) { split(dl, dd, FS); if (dd[1]!="") dns[dd[1]]=dd[2] } close(dnsfn) }
            if (ipfn!="") { while ( (getline il < ipfn) > 0 ) { split(il, ii, FS); if (ii[1]!="") ipm[ii[1]]=ii[2] } close(ipfn) }
            # Build highlight sets from comma-separated lists
            nh=split(hilites, hh, ","); for (i=1;i<=nh;i++){ gsub(/^\s+|\s+$/, "", hh[i]); if (hh[i]!="") HL[hh[i]]=1 }
            nd=split(hilitedns, hd, ","); for (i=1;i<=nd;i++){ gsub(/^\s+|\s+$/, "", hd[i]); if (hd[i]!="") HLDNS[hd[i]]=1 }
            nn=split(hilitename, hn, ","); for (i=1;i<=nn;i++){ gsub(/^\s+|\s+$/, "", hn[i]); if (hn[i]!="") HN[i]=hn[i] }; HN_len=nn
            no=split(onlyname,  on, ","); for (i=1;i<=no;i++){ gsub(/^\s+|\s+$/, "", on[i]); if (on[i]!="") ON[i]=on[i] }; ON_len=no
        }
        (FILENAME==prevfn){ prev[$3]=$0; next }
        {
            key=$3
            if(!(key in prev)) next
            split(prev[key],p,FS)
            # Fields: 1=band 2=ssid 3=mac 4=host 5=signal 6=txp 7=txr 8=txf 9=ts
            dtx=$6-p[6]
            if(dtx<0) next
            if(hide=="1" && dtx==0) next
            # iw data uses -1 as sentinel for "not yet available"
            # Suppress retry columns entirely if either snapshot lacks iw data
            iw_ok=($7+0 >= 0 && p[7]+0 >= 0)
            if (iw_ok) { dr=$7-p[7]; df=$8-p[8]; if(dr<0||df<0) next }
            else { dr=0; df=0 }
            a1=dtx; a2=dtx+df
            r1=(a1>0)?(dr*100.0/a1):0
            r2=(a2>0)?(dr*100.0/a2):0
            if ((idebug+0)>0) {
                # Log per-interval packet deltas and computed ratio
                printf("%s\tmac=%s\td_tx=%d\td_r=%d\td_f=%d\tr/(tx+f)=%.4f%%\n", now_hms, key, dtx, dr, df, r2) >> idbgfile
            }
            # Per-MAC rolling window: sum per-cycle deltas within the trailing window.
            # History records contain deltas (not cumulative values) so no baseline
            # arithmetic is needed — just sum what is inside the window.
            hist=wdir "/" key ".hist"; winp_val=0; denom=0; wtx=0; wr=0; wf=0;
            snap_ts=$9+0; cutoff=snap_ts-win_secs; min_ts=-1
            while ( (getline line < hist) > 0 ) {
                split(line, hh, " ")
                ts=hh[1]+0
                if (min_ts<0) min_ts=ts
                if (ts <= cutoff) continue  # outside window; skip but keep reading for min_ts
                wtx += hh[2]+0; wr += hh[3]+0; wf += hh[4]+0
            }
            close(hist)
            if (win_formula=="r1") { denom=wtx }
            else if (win_formula=="r3") { denom=wtx+wf+wr }
            else { denom=wtx+wf }
            if (denom>0) { winp_val=wr*100.0/denom; if (winp_val>100) winp_val=100 }
            # Gate display: iw must be available, window must be full, minimum traffic required
            age = (min_ts>0) ? (snap_ts - min_ts) : 0
            if (!iw_ok) {
                win_str = ""
            } else if ((win_partial+0)==1) {
                win_str = (denom>0 ? sprintf("%.1f%%", winp_val) : "")
            } else {
                ready = (age>=win_secs && denom>0 && wtx>=win_min_pkts+0) ? 1 : 0
                win_str = (ready ? sprintf("%.1f%%", winp_val) : "")
            }
            if (dbg+0>0) {
                printf("%s\t%s\tsnap=%d min_ts=%d age=%d wtx=%d wr=%d wf=%d denom=%d win=%.2f ready=%d\n", now_hms, key, snap_ts, min_ts, age, wtx, wr, wf, denom, winp_val, ready) >> dbgfile
            }
            snr_str=""; if (($1 in noise) && noise[$1] <= -40) { snr_val=$5 - noise[$1]; snr_str = sprintf("%d", snr_val) }
            # Read negotiated Tx/Rx rates from cur.tsv fields 11 (rxrate) and 12 (txrate)
            rxrate_val=$11; txrate_val=$12
            rxrate_str=(rxrate_val!="" && rxrate_val!="-" ? rxrate_val " Mbps" : "-")
            txrate_str=(txrate_val!="" && txrate_val!="-" ? txrate_val " Mbps" : "-")
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
            # -n/-h/-d highlight: bold matching rows
            matched=0
            if ($4 in HL || dns_out in HLDNS) matched=1
            if (!matched) { for (i=1;i<=HN_len;i++) { if (HN[i]!="" && (index($4,HN[i])>0 || index(dns_out,HN[i])>0)) { matched=1; break } } }
            # -o filter: hide rows that do not match; bold those that do
            if (ON_len>0) {
                only_matched=0
                for (i=1;i<=ON_len;i++) { if (ON[i]!="" && (index($4,ON[i])>0 || index(dns_out,ON[i])>0)) { only_matched=1; break } }
                if (!only_matched) next
                matched=1
            }
            if (matched) { pre="\033[1m"; post="\033[0m" } else { pre=""; post="" }
            if (show_mac+0 == 1) {
                line = sprintf("%s%-7s %-12s %-22s %-20s %-15s %-17s %5d %6d %7.1f%%   %7s %9s %6s  %9s %9s%s",
                                pre, $1, $2, dns_out, ($4==""?"-":$4), ip_out, $3, dtx, dr, r2, win_str, sig_out, snr_out, txrate_str, rxrate_str, post)
            } else {
                line = sprintf("%s%-7s %-12s %-22s %-20s %-15s %5d %6d %7.1f%%   %7s %9s %6s  %9s %9s%s",
                                pre, $1, $2, dns_out, ($4==""?"-":$4), ip_out, dtx, dr, r2, win_str, sig_out, snr_out, txrate_str, rxrate_str, post)
            }
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
bootstrap_from_arp >/dev/null 2>&1 &  # background: ARP+nslookup hostnames, one by one
build_ssid_map                         # fast SSID population before first frame
start_hostmap_updater                  # background: hostname/DNS/SSID/ifaces every HOST_CACHE_SEC
start_iw_updater                       # background: iw retries/failed every IW_CACHE_SEC
start_noise_updater                    # background: noise floor every NOISE_CACHE_SEC
while :; do
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
        printf "Priming counters...\n"
        # Initialize per-MAC history directory
        mkdir -p "$WINDOW_DIR" 2>/dev/null || true
    fi
    # Keep current snapshot available for external inspection; copy to prev
    cp -f "$STATE_CUR" "$STATE_PREV" 2>/dev/null || true
    # Maintain target cadence; on the first cycle use PRIME_MS for a faster startup
    end_ms=$(now_ms)
    elapsed=$((end_ms - start_ms))
    if [ -s "$STATE_PREV" ] && [ ! -s "$BASE_DIR/ui_lines.count" ]; then
        wait_ms=$((PRIME_MS - elapsed))
    else
        wait_ms=$((REFRESH_MS - elapsed))
    fi
    if [ "$wait_ms" -lt 1 ]; then wait_ms=1; fi
    log_ts "sleep ${wait_ms}ms (elapsed=${elapsed}ms)"
    sleep_ms "$wait_ms"
    
done
