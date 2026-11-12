NTRIP Scope Android **0.4.2**, version code **13**, Android 7.0+.

## Added since Android 0.1.4

- Simultaneous file, TCP server and Bluetooth Classic SPP outputs, including bidirectional receiver GGA uplink and manual-coordinate priority.
- Separate caster/receiver live HEX and ASCII panels, stable RTCM frame selection, Fields/Measurements and per-satellite/signal C/N₀ chart.
- Receiver fix quality from GGA, source, age and stale/paused indications.
- Street/offline map, receiver/manual rover, station-to-rover distance, scale, decimal/DMS coordinates and ellipsoidal height when available. Preserved zoom and Show both. GPS sky uses healthy RTCM 1019 plus GPS MSM epochs.
- Optional Keep streaming with screen off: foreground service, notification Stop and power-management settings. With the option off, backgrounding closes connections; serialized cleanup waits before reopening Bluetooth/caster resources.
- Save configuration can select an existing file, confirm overwrite, or reuse/change its name for a new copy. Passwords are excluded from exports.
- About screen with author, version, license and GitHub link.
- 0.4.2 fixes incomplete first map display without needing a pan or zoom gesture.

## Installation

Open the APK on your phone and permit installation from that source if requested. Updates from 0.1.5 onward share the signing certificate and can be installed over the existing app. The older 0.1.4 preview has a different signature: export settings, uninstall that preview, then install this APK. Removing only the home-screen icon does not uninstall the app.

## Validation and limitations

40 Flutter tests passed in 0.4.2; static analysis clean and release APK signature/version verified. The unchanged native service/file/Bluetooth shutdown code passed 13 tests in 0.4.1, including simulated Android 16 cases. Screen-off streaming was confirmed by the user on a physical phone with 0.4.0. The revised standby Bluetooth reconnection still requires physical-device confirmation, including Samsung Android 16/One UI 8.0. Phone power settings can limit background operation.

USB serial is not implemented. GPS sky currently plots GPS only. iOS remains a source-based development preview using BLE rather than generic Classic SPP; no new iOS binary is provided here.

Source ZIP contains the shared Android/iOS project, tests and build/installation guide. Private signing keys and local operational notes are excluded.
