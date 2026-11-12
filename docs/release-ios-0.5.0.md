# NTRIP Scope iPhone/iPad 0.5.0

Development preview, build 15, iOS/iPadOS 15+. This release brings iPhone/iPad up to the compatible shared functionality in Android 0.4.3 and completes native iOS paths.

## Features

- Separate caster/receiver HEX/ASCII, RTCM Fields/Measurements with stable live/history selection, per-satellite/signal C/N₀, GPS sky and street/offline maps.
- Map initialization/zoom fixes, Show both, mountpoint name, rover from GGA/manual coordinates, distance, decimal/DMS coordinates, ellipsoidal height when available and original receiver fix with source/age/STALE/PAUSED.
- Simultaneous direct file RTCM, local/LAN TCP and configurable bidirectional BLE; manual GGA retains priority.
- Configuration save with remembered name, existing-file selection, explicit overwrite confirmation or new copy. Passwords are omitted.
- Remembered BLE profile, OS-confirmed disconnect before reopening, bounded background cleanup and Keep screen awake while streaming.

## Downloads and installation

The project ZIP includes the shared source, native iOS implementation, tests and a helper that prepares Flutter and opens Xcode. Install on a physical iPhone/iPad with your own Apple Account/Team and valid provisioning.

The simulator ZIP is for the iOS simulator on Apple Silicon Macs; it cannot be installed on a phone. No private development IPA, personal provisioning profile or signing key is published.

See the [installation and troubleshooting guide](https://github.com/zuliani71/NTRIP-Scope/blob/main/docs/iphone-ipad.md), including developer-disk-image errors caused by a locked device.

## Platform differences and validation

iOS uses BLE, not generic Bluetooth Classic SPP; HC-06 does not appear in the BLE scan. Screen lock/background closes the session. Keep screen awake prevents automatic lock in the foreground and does not provide Android-style continuous screen-off streaming. USB serial is not implemented. GPS sky requires healthy RTCM 1019 and GPS MSM and currently plots GPS only.

41 shared Flutter tests, four native XCTest checks and three integration tests on each of iPhone/iPad simulators passed. Normal simulator app launched; a device release was signed/verified locally. Physical BLE and real Files/iCloud-provider validation remain pending. Android APK remains 0.4.3; main's shared mobile source is 0.5.0.
