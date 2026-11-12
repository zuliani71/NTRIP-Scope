# NTRIP Scope

<img src="assets/orbit.png" alt="NTRIP Scope satellite application icon" width="128">

NTRIP Scope includes a graphical desktop client with a live RTCM3 decoder and a command-line client, `ntripscope`, for macOS, Windows and Linux. The desktop interface is available in English and Italian. A mobile diagnostic client is available for Android. A development preview for iPhone and iPad can be built from source with Xcode. The command-line client can list mountpoints and stream raw RTCM to standard output for scripting, or forward it to files, TCP and serial ports.

## What is new

### Desktop 1.35 and command-line 1.32

- Bidirectional receiver connections send RTCM to the receiver and forward checksum-valid GGA to the caster for VRS. macOS uses native RFCOMM for HC-06; Windows/Linux use the serial ports exposed by the operating system. Enabled manual rover coordinates take priority.
- Separate caster and receiver HEX/ASCII panels make both directions readable. RTCM latest-frame updates and historical selection remain independent of receiver traffic.
- RTCM Fields, Measurements and C/N₀ views, resizable upper/lower decoder panes and an upper-list scrollbar on Windows/Linux. Decoded field coverage varies by decoder and message type.
- **Receiver fix** reports GGA quality (including NO FIX, RTK FLOAT and RTK FIXED), source, age, stale and paused states. It reports receiver quality, not an independent accuracy estimate.
- Maps show the mountpoint, receiver/manual rover, connecting line and distance, coordinate formats and ellipsoidal height when known. Rover updates preserve zoom; **Show both** fits the two positions.
- Map & sky and Live stream are independent desktop windows. On macOS they remain open when another app gains focus. Initial decoder layout and left alignment have been corrected.
- Compact header with icon, visible version, author/GitHub information; shared INI import/export. Stop freezes views and preserves the last station for the same caster/mountpoint; **Disconnect receiver** explicitly releases the receiver.
- CLI 1.32 supports receiver GGA through bidirectional serial/SPP, with native macOS HC-06 RFCOMM. Standard output remains the default RTCM destination; file/TCP/serial destinations can run together.

### Android 0.4.2

- Bidirectional Bluetooth Classic SPP, file and TCP outputs can run together. Separate receiver/caster inspection, receiver fix status and manual-GGA priority are available.
- RTCM Fields/Measurements, per-satellite/signal C/N₀ chart and GPS sky plot. Sky requires healthy RTCM 1019 ephemerides and a GPS MSM epoch; other constellations are not plotted.
- Optional **Keep streaming with screen off** uses a foreground service and a notification with Stop. When disabled, backgrounding closes the caster and outputs; cleanup is serialized before reconnection. Phone power settings may restrict background operation.
- Configuration saving can select an existing file, confirm replacement, or reuse its name to save a new copy. Exported configurations omit passwords.
- First map opening now initializes the camera without requiring pan or zoom to complete tile display; zoom is preserved when the rover moves.

Validation: desktop packages passed the recorded macOS checks and Windows/Linux GUI and executable checks (Windows 11, Ubuntu ARM64 and x64). Android 0.4.2 passed 40 Flutter tests; the unchanged native shutdown/file/service code passed 13 tests in 0.4.1, including simulated Android 16 cases. The user confirmed screen-off streaming on a real phone with 0.4.0. Receiver-specific reconnection after standby still needs physical-device confirmation. No new iOS binary is provided in this update.

## Downloads

### Desktop client

Choose the package for your system from the [v1.35 release](https://github.com/zuliani71/NTRIP-Scope/releases/tag/v1.35).

| Platform | Package |
|---|---|
| macOS 13+ on Apple Silicon | [Download macOS ARM64](https://github.com/zuliani71/NTRIP-Scope/releases/download/v1.35/NTRIP-Scope-macos-arm64-1.35.zip) |
| Windows x64 | [Download Windows x64](https://github.com/zuliani71/NTRIP-Scope/releases/download/v1.35/NTRIP-Scope-windows-x64-1.35.zip) |
| Linux ARM64 · Ubuntu in Parallels on Apple Silicon | [Download Linux ARM64](https://github.com/zuliani71/NTRIP-Scope/releases/download/v1.35/NTRIP-Scope-linux-arm64-1.35.tar.gz) |
| Linux x64 · Intel or AMD | [Download Linux x64](https://github.com/zuliani71/NTRIP-Scope/releases/download/v1.35/NTRIP-Scope-linux-x64-1.35.tar.gz) |

On Linux, run `uname -m` to check your architecture. Use ARM64 for `aarch64` and x64 for `x86_64`. The Linux x64 build targets Ubuntu 22.04 or compatible systems. The Linux ARM64 build targets Ubuntu 24.04 or compatible systems.

### Command-line client

Download the [cross-platform Python source package (CLI 1.32)](https://github.com/zuliani71/NTRIP-Scope/releases/download/v1.35/ntripscope-1.32-sorgenti.zip), which requires Python 3.10+ and the dependencies in `src/portable/requirements.txt`. Standalone Windows/Linux executables are included in the desktop packages. A [standalone macOS ARM64 CLI](https://github.com/zuliani71/NTRIP-Scope/releases/download/v1.35/ntripscope-macos-arm64-1.32.zip) is also available.

From the extracted source folder, run:

```sh
cd src/portable
python3 -m pip install -r requirements.txt
python3 ntripscope.py --host caster.example.org --port 2101 --list
python3 ntripscope.py --config ntripscope-vrs.example.ini
```

The default output is binary RTCM on stdout. Use the repeatable `--file`,
`--tcp` and `--serial` options to forward the stream to multiple destinations.
See the [CLI guide and full INI syntax](src/portable/ntripscope.md), the
[basic example](src/portable/ntrip-scope.example.ini) and the
[VRS example](src/portable/ntripscope-vrs.example.ini).
Build a standalone executable on the target system with
`python src/portable/build.py --cli` after installing the build requirements.

### Android client

[Download Android 0.4.2 APK](https://github.com/zuliani71/NTRIP-Scope/releases/download/android-v0.4.2/NTRIP-Scope-Android-0.4.2.apk) (Android 7.0+). Open it on the phone and allow installation from the app used to open the file if requested. Builds from 0.1.5 onward share the same signing certificate. The old 0.1.4 preview used a different certificate: export settings and uninstall that preview before installing the new APK.

Android supports simultaneous file, TCP server and paired Bluetooth Classic SPP outputs, receiver GGA uplink, live diagnostics, maps and GPS sky. USB serial is not implemented. See the [mobile guide](src/mobile/README.md) and [Android release notes](https://github.com/zuliani71/NTRIP-Scope/releases/tag/android-v0.4.2).

### iPhone and iPad client

The development preview supports iOS and iPadOS 15 or later. Build and install it from source on your own device using Xcode and your Apple Account. The app has launched in the iPhone simulator and installed on a physical iPhone. The first launch on the physical device still needs verification.

The historical [0.1.4 simulator build](https://github.com/zuliani71/NTRIP-Scope/releases/download/android-v0.1.4/NTRIP-Scope-iOS-0.1.4-Simulator.zip) includes the new About screen. For a physical device, see the [installation and troubleshooting guide for iPhone and iPad](src/mobile/README.md#iphone-e-ipad).

## Screenshots

| Live NTRIP connection | Rover and mountpoint map |
| --- | --- |
| ![NTRIP Scope receiving data from a connected caster](docs/screenshots/live-connection.png) | ![Street map showing the rover, mountpoint and distance between them](docs/screenshots/rover-map.png) |

| RTCM3 decoder and C/N₀ chart | Measurements by satellite and signal |
| --- | --- |
| ![RTCM3 decoder showing GPS MSM5 and carrier-to-noise density by satellite slot](docs/screenshots/rtcm-cnr.png) | ![Table showing pseudorange, phase range, C/N₀ and range rate for GPS signals](docs/screenshots/rtcm-measurements.png) |

## Features

| Capability | Desktop client | Command-line client |
|---|---|---|
| NTRIP connection | NTRIP 1.0 and 2.0, authentication, TLS and mountpoint selection from the sourcetable | NTRIP 1.0 and 2.0, authentication, TLS and mountpoint listing with `--list` |
| Rover position for VRS | Decimal and sexagesimal coordinate entry with automatic conversion and periodic GGA | Decimal coordinates via arguments/INI, or receiver GGA over bidirectional serial/SPP; manual coordinates take priority |
| RTCM outputs | Optional file, local TCP and serial outputs. Monitor with all outputs disabled | Raw binary RTCM on standard output by default. Repeatable file, TCP and serial destinations, with optional simultaneous standard output |
| Shared configuration | Import/export INI with **Options → Load/Save configuration…** | Read an INI with `--config`. Command-line options override corresponding file settings |
| Stream inspection | Live HEX and ASCII, CRC checks, frame history, RTCM3 fields, MSM measurements and a C/N₀ chart | Raw stream for processing by scripts or external decoders. Status and errors go to standard error |
| Receiver diagnostics | Separate caster/receiver HEX and ASCII; GGA fix status, source and age | Receiver GGA uplink; headless operation, no GUI decoder or charts |
| Map and GPS sky | Separate windows with street and offline maps, scale, rover-to-mountpoint distance and GPS tracks when ephemerides are available | Headless operation for scripts and automated workflows |

Android additionally offers the graphical decoder, C/N₀ chart, map/GPS sky, INI import/export, file/TCP/Bluetooth outputs and the optional screen-off service described above. It does not provide a command-line interface or USB serial. iOS remains a development preview with BLE rather than generic Classic SPP.

The street map uses Apple Maps on macOS and OpenStreetMap on Windows and Linux. GPS tracks require broadcast RTCM 1019 ephemerides and a GPS MSM epoch.

## Share an INI configuration

The desktop app can load the same file used by `ntripscope --config`.
Choose **Options → Load configuration…** to populate the caster, mountpoint, credentials, rover coordinates for VRS, and file, TCP and serial outputs. Then choose **Connect** or **Fetch mountpoints**.
The CLI settings `stdout` and `list` apply only to command-line runs.
The macOS desktop app accepts multiple files, one TCP port and one serial device per session.
Use a serial device name appropriate for the system where the configuration runs.
Use **Options → Save configuration…** to export caster settings, rover coordinates and enabled desktop outputs. Enter the password again after loading an exported file.

## Source layout

| Directory | Contents |
|---|---|
| [src/macos/](src/macos/) | Native macOS app in Swift and its build script |
| [src/portable/](src/portable/) | Shared Windows and Linux desktop app and cross-platform command-line client in Python |
| [src/mobile/](src/mobile/) | Android diagnostic client and iPhone project in Flutter |
| [assets/](assets/) | Shared map, icon and localization files |

## Run from source

Use Python 3.10+ with Tk. On Debian/Ubuntu install `python3-tk` and `python3-venv`. On Windows, install Python with the Tcl/Tk option enabled.

```sh
python -m venv .venv
```

Activate the environment with `.venv\Scripts\Activate.ps1` on Windows PowerShell or `source .venv/bin/activate` on Linux. Then run:

```sh
python -m pip install -r src/portable/requirements.txt
python src/portable/app.py
```

On Linux, the account running the app needs access to the selected serial device. TCP output listens on `127.0.0.1` and supports one receiving client at a time.

## Build and test

Run these commands on the target operating system:

```sh
python -m pip install -r src/portable/requirements-build.txt
python -m unittest discover -s src/portable/tests -v
python src/portable/build.py
```

The executable appears in `dist/`. To rebuild the macOS archive on an Apple Silicon Mac with the Swift toolchain, run `sh src/macos/build.sh`.

## Credits

The portable decoder uses [pyrtcm](https://github.com/semuconsulting/pyrtcm), serial I/O uses [pySerial](https://github.com/pyserial/pyserial), and executable packaging uses [PyInstaller](https://pyinstaller.org/). The portable basemap is made with [Natural Earth](https://www.naturalearthdata.com/about/terms-of-use/) public-domain 1:110m land data, version 5.1.2. The portable street map uses [OpenStreetMap](https://www.openstreetmap.org/copyright) under its [tile usage policy](https://operations.osmfoundation.org/policies/tiles/).

## License

NTRIP Scope is distributed under the [MIT License](LICENSE), copyright © 2026 zuliani71. Preserve the copyright and license notice when redistributing the software. Third-party components retain their own licenses.

Original documentation, research papers, and datasets that the project publishes will be shared under the [Creative Commons Attribution 4.0 International license (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/), unless the material specifies a different license. Third-party materials retain their respective licenses.
