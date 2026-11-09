# NTRIP Scope

Desktop NTRIP client and RTCM3 stream inspector with English and Italian interfaces.

## Download

Choose the package for your system from the [v1.10 release](https://github.com/zuliani71/NTRIP-Scope/releases/tag/v1.10).

| Platform | Package |
|---|---|
| macOS 13+ on Apple Silicon | [Download macOS ARM64](https://github.com/zuliani71/NTRIP-Scope/releases/download/v1.10/NTRIP-Scope-macos-arm64.zip) |
| Windows x64 | [Download Windows x64](https://github.com/zuliani71/NTRIP-Scope/releases/download/v1.10/NTRIP-Scope-windows-x64.zip) |
| Linux ARM64 · Ubuntu in Parallels on Apple Silicon | [Download Linux ARM64](https://github.com/zuliani71/NTRIP-Scope/releases/download/v1.10/NTRIP-Scope-linux-arm64.tar.gz) |
| Linux x64 · Intel or AMD | [Download Linux x64](https://github.com/zuliani71/NTRIP-Scope/releases/download/v1.10/NTRIP-Scope-linux-x64.tar.gz) |

On Linux, run `uname -m` to check your architecture. Use ARM64 for `aarch64` and x64 for `x86_64`. The Linux binaries target Ubuntu 22.04 or compatible systems.

## Features

- NTRIP 1.0 and 2.0, caster authentication, TLS and mountpoint discovery.
- Rover coordinates in decimal degrees or degrees, minutes and seconds. GGA for VRS, with periodic updates.
- Optional raw RTCM recording, loopback TCP forwarding and serial output. You can monitor a stream with all outputs off.
- Live HEX and ASCII, CRC validation, frame history by RTCM type, decoded fields, MSM observations and a C/N₀ chart.
- Independent map and GPS sky windows. When rover coordinates are entered, a blue marker and a labelled baseline show the approximate horizontal distance to the mountpoint. Choose Street map for roads and place names or Offline map for the bundled Natural Earth basemap. The street view uses Apple Maps on macOS and OpenStreetMap on Windows and Linux. The portable app requests and caches only the visible OpenStreetMap tiles. Switch to Offline map to keep the view local. GPS tracks require broadcast RTCM 1019 ephemerides and a GPS MSM epoch from the selected stream.

## Source layout

| Directory | Contents |
|---|---|
| [src/macos/](src/macos/) | Native macOS app in Swift and its build script |
| [src/portable/](src/portable/) | Shared Windows and Linux app in Python |
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
