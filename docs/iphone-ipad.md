# NTRIP Scope for iPhone and iPad

Version 0.5.0 is a development preview for iOS/iPadOS 15 or later. It shares diagnostics with Android through version 0.4.3 and adds the native iOS document, file-output and lifecycle paths. The same project supports iPhone and iPad.

## Features and differences

Separate caster/receiver HEX and ASCII, RTCM Fields/Measurements with stable history, per-satellite/signal C/N₀, GPS sky and street/offline maps are included. The map displays the mountpoint name, receiver/manual rover, distance, coordinates and original receiver fix quality. Enabled manual coordinates take priority for GGA sent to the caster and do not create a receiver RTK status.

File RTCM and a TCP server can run alongside bidirectional BLE (RTCM to receiver, GGA back to the caster). Record RTCM is a separate temporary-capture/export option. A selected direct-output file is replaced when connecting; disable file output to use diagnostics only. TCP serves one client at a time and has no authentication; local-network access is optional.

Save configuration remembers a name, can select an existing document, confirms replacement, or creates a new copy when the name changes. Selection alone neither overwrites nor imports the file. Exported passwords are omitted. Read-only, moved or unavailable documents produce an error; Files/iCloud providers may require access or a download.

## Bluetooth receiver requirements

Use a BLE UART-style service exposing a writable RTCM characteristic and a notifying/indicating receiver-data characteristic. Enter the manufacturer's service/write/read UUIDs under **Bluetooth LE receiver**, then scan and select the receiver. The initial UUIDs are Nordic UART Service defaults; change them when the receiver uses another profile. Profiles are remembered.

HC-06 is Bluetooth Classic SPP and does not appear in this BLE scan. Use it with Android or desktop, or use a suitable BLE receiver/adapter for iOS. A Bluetooth version number alone does not establish compatibility. A dual-mode adapter may provide SPP for Android/desktop and BLE for iOS, but its actual firmware, UART profile, flow control and sustained RTCM throughput must be checked. No specific replacement module is certified by this release.

## Screen lock and Stop

**Keep screen awake while streaming** prevents automatic screen lock only while the app and stream are active in the foreground. Manual screen lock or leaving the app closes the session. Native code uses iOS's finite background time to finish caster/TCP/file/BLE cleanup. Reconnection waits for the previous BLE disconnect to be confirmed. This is not equivalent to Android's optional screen-off foreground service.

Apple background-task documentation: https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:)

## Install on a physical device

1. Install Flutter and complete Xcode on a Mac. Add Flutter's `bin` to PATH (or set `FLUTTER_ROOT`). Run `flutter doctor` to check the environment.
2. Download and extract the [0.5.0 Xcode project](https://github.com/zuliani71/NTRIP-Scope/releases/download/ios-v0.5.0/NTRIP-Scope-iOS-0.5.0-progetto.zip).
3. Run `Prepara-e-apri-iOS.command` inside the extracted project. It fetches dependencies, prepares the iOS build configuration and opens `ios/Runner.xcworkspace`.
4. In Xcode, select the blue **Runner** project, the **Runner** target, then **Signing & Capabilities**. Select your **Team** and automatic signing. If needed, add your Apple Account in Xcode Settings and choose a unique bundle identifier for your own team.
5. Connect and unlock the iPhone/iPad, trust the Mac if prompted, enable Developer Mode when requested, select the physical device as the run destination and press **Run**.
6. Complete any signing/trust prompts on the Mac and device. Keep the phone unlocked during preparation and installation.

Development signing may expire; rebuild with your own Team when needed. The public project contains no private signing keys, personal Team identifier or device provisioning profile. A device-specific development IPA is not a general public iPhone installer and is not distributed in this release.

Manual preparation from the project directory:

```sh
flutter pub get
BYPASS_PERMISSION_LOCATION_ALWAYS=1 flutter build ios --debug --config-only --no-codesign
open ios/Runner.xcworkspace
```

## Simulator

The [0.5.0 simulator ZIP](https://github.com/zuliani71/NTRIP-Scope/releases/download/ios-v0.5.0/NTRIP-Scope-iOS-0.5.0-Simulator.zip) is built for an Apple Silicon Mac's iOS simulator. Extract `Runner.app`, start a compatible simulator and install it with Xcode tools:

```sh
xcrun simctl install booted /path/to/Runner.app
xcrun simctl launch booted io.github.zuliani71.ntripscopeMobile
```

It cannot run on a physical iPhone or replace a real BLE receiver test.

## Troubleshooting

- **Device missing:** unlock it, use a data-capable USB cable, trust the Mac and check Xcode's Window → Devices and Simulators. Reconnect if needed.
- **Developer disk image could not be mounted / error 12040:** read the nested cause. If it says `kAMDMobileImageMounterDeviceLocked` or `The device is locked`, unlock with the device passcode, leave the Home screen visible and retry while the screen stays on. That nested cause does not require reinstalling the app or changing Bluetooth hardware.
- **Signing or provisioning failure:** check Team, bundle identifier and run destination. A profile must include the intended physical device and be valid.
- **HC-06 missing from scan:** expected on iOS; it uses Classic SPP, not BLE.
- **BLE device found but no data:** verify the actual service and write/notify UUIDs, characteristic permissions and any extra manufacturer protocol/flow control. BLE radio tests remain receiver-specific.
- **Old configuration selected for saving:** selection does not import its settings. Use Load configuration to import; use Save changes and confirm Replace to overwrite, or change the name to save a new copy.

## Recorded validation

41 shared Flutter tests, four native XCTest document checks and three integration tests on each of the iPhone and iPad simulators passed. Integration checks cover UI options, native channels and real local TCP/caster sockets with Stop/reconnection. The normal simulator app was launched, and a physical-device release build was signed and verified locally. This does not certify physical BLE, all Files/iCloud providers or every phone's background behavior. Real receiver/provider validation remains pending.
