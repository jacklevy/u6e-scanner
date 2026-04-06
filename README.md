# u6e-scanner
real-time client scanner for Ubiquiti U6 Enterprise

![screenshot](docs/images/screenshot.png)

this tool monitors signal strength, retry rates and upload/download throughput stability for the purpose of diagnosing performance/interference and tuning WAP/client positioning in real-time.

### features

* identifies clients using both dns and hostname
* displays band, ssid, ip, and mac metadata for each client
* signal strength presented in both dBm and snr relative to floor, along with negotiated tx and rx rates
* displays snapshot values for transmit (d_tx), receive (d_r) and transmit retry % for rolling 5s and 30s windows (txr%) on each refresh
* highlight host rows for easy identification via `-n` option or display select clients with the `-o` option
* many parameters configurable via env vars (see script comments)

### notes and caveats

* complete usage, implementation and column documentation reside in comments at the top of the script
* this script does not modify anything on the system other than caching data in `/tmp/u6e-scanner`, but don't take my word for it - review the code to verify safety and security
* AI tools were used to generate much of this code - do not use it if that is an issue for you
* this may break with new U6E firmware updates
* this may or may not work on other ubiquiti WAPs

### compability

verified working on U6E firmware 6.8.2.15592 as of April 2026
