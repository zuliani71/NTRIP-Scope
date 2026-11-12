# NTRIP Scope Android 0.4.3

Android 0.4.3, version code14, Android 7.0+.

## New in 0.4.3

- The information below the map includes the selected mountpoint name.
- Rover details show original receiver GGA fix quality, source and age; NO FIX, RTK FLOAT, RTK FIXED, STALE and PAUSED are represented.
- Fix updates remain visible without rover movement or valid rover coordinates. Enabled manual coordinates retain uplink priority and do not imply an RTK fix.

Retains the first-map-loading correction from 0.4.2, configuration overwrite confirmation, optional screen-off streaming, bidirectional Bluetooth Classic SPP, simultaneous file/TCP outputs, separate streams, RTCM Fields/Measurements, C/N₀ and GPS sky.

## Installation and validation

Install the APK over builds 0.1.5 onward; the signing certificate is unchanged. The much older 0.1.4 preview used a different certificate: export settings before uninstalling that preview. Removing only its home-screen icon is not uninstalling it.

41 Flutter tests and static analysis passed; release APK version and signature verified. No native Android code changed from 0.4.1 (13 native tests passed there, including simulated Android 16 shutdown cases). Physical receiver reconnection after standby still requires device-specific testing. USB serial is not implemented.

The source ZIP is the exact 0.4.3 snapshot; main now also contains newer shared changes for iOS0.5.0. The latest published Android APK remains0.4.3.
