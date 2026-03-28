# u6e-scanner
real-time client scanner for Ubiquiti U6 Enterprise

![screenshot](docs/images/screenshot.png)

this tool monitors signal strength, retry rates and upload/download throughput stability for the purpose of diagnosing performance/interference and tuning WAP/device positioning in real-time.

### features

* identifies clients using both dns and hostname
* displays band, ssid, ip, and mac metadata for each client
* signal strength present in both dBm and snr relative to floor
* displays snapshot values for transmnit (d_tx), receive (d_r) and transmit retry (d_TxR%) on each refresh
* rolling windows calculations for average transmit retry (TxR%) and 5th percentile upload/download speeds
* highlight host rows for easy identification via `-h` option
* many parameters configurable via env vars (see script comments)

### notes and caveats

* usage and column documentation reside in comments at the top of the script
* this script does not modify anything on the system other than caching data in `/tmp/u6e-scanner`, but don't take my word for it - review the code to verify it is safe and secure
* AI tools were used to generate much of this code - do not use it if this is an issue for you
* this may break with new U6E firmware updates
* this may or may not work on other ubiquiti WAPs

### compability

verified working on U6E firmware 6.8.2.15592 as of March 2026
