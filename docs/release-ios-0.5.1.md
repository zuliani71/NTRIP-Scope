# NTRIP Scope iPhone/iPad 0.5.1

Development preview, build 16, iOS/iPadOS 15+.

## Experimental screen-off BLE continuity

- New **Keep BLE and stream in background (experimental)** preference, off by default and separate from Keep screen awake.
- Official `bluetooth-central` mode. Native code requires an actual connected, subscribed BLE receiver with a writable RTCM characteristic; a selection or client-side flag alone cannot enable continuity.
- Without ready BLE or after BLE loss in background, controlled shutdown closes caster/file/TCP/BLE. Stop and force quit stop the session; no restart after OS termination.
- On foreground return, a local caster receive gap over 20 seconds stops the session and asks for reconnection. This does not measure GNSS correction age.
- BLE close callbacks respect the disconnect barrier and generation, avoiding interference from old closure timers.

**iOS may suspend network/Dart execution even while BLE is retained. Uninterrupted RTCM at screen lock is not guaranteed and requires prolonged physical-device validation.** No physical BLE test has been completed. File providers may also restrict writes while locked. HC-06 Classic is still incompatible with iOS BLE.

## Downloads

Project ZIP: source, tests and helper to prepare Flutter/open Xcode. Use your own Apple Account/Team to sign for a physical device. Simulator ZIP: Apple Silicon Mac iOS simulator only, not installable on a phone. No private development IPA, provisioning profile or signing keys are included.

[Installation, BLE and troubleshooting guide](https://github.com/zuliani71/NTRIP-Scope/blob/main/docs/iphone-ipad.md).

## Validation

Static analysis clean; 45 shared Flutter tests, eight native XCTest checks and three integration tests on each iPhone/iPad simulator passed. The four new Flutter scenarios use a simulated BLE link and real local caster sockets; native policy checks do not simulate a real radio. Device release built/signed and codesign-verified locally; simulator build completed. No prolonged physical background BLE/network test.

Desktop 1.36, Android APK 0.4.3 and CLI 1.32 remain unchanged. Main's shared mobile source version is 0.5.1.
