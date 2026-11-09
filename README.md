# NTRIP Scope

Desktop NTRIP client and RTCM3 stream inspector with English and Italian interfaces.

| Platform | App |
|---|---|
| macOS 13+ on Apple Silicon | Native SwiftUI app. The ad-hoc-signed build is in [macos/](macos/). |
| Windows x64 | Portable desktop app. Run from source or obtain `NTRIP-Scope.exe` from a successful Windows build. |
| Linux x64 and ARM64 | Portable desktop app. Run from source or obtain the executable archive from a successful Linux build. The binaries target Ubuntu 22.04 or compatible systems. Run `uname -m` to select the archive. Use `linux-arm64` for `aarch64` (including Ubuntu in Parallels on Apple Silicon), and `linux-x64` for `x86_64`. |

## Features

- NTRIP 1.0 and 2.0, caster authentication, TLS and mountpoint discovery.
- Rover coordinates in decimal degrees or degrees, minutes and seconds. GGA for VRS, with periodic updates.
- Optional raw RTCM recording, loopback TCP forwarding and serial output. You can monitor a stream with all outputs off.
- Live HEX and ASCII, CRC validation, frame history by RTCM type, decoded fields, MSM observations and a C/N₀ chart.
- Independent map and GPS sky windows. When rover coordinates are entered, a blue marker and a labelled baseline show the approximate horizontal distance to the mountpoint. Choose Street map for roads and place names or Offline map for the bundled Natural Earth basemap. The street view uses Apple Maps on macOS and OpenStreetMap on Windows and Linux. The portable app requests and caches only the visible OpenStreetMap tiles. Switch to Offline map to keep the view local. GPS tracks require broadcast RTCM 1019 ephemerides and a GPS MSM epoch from the selected stream.

## Run from source

Use Python 3.10+ with Tk. On Debian/Ubuntu install `python3-tk` and `python3-venv`. On Windows, install Python with the Tcl/Tk option enabled.

```sh
python -m venv .venv
```

Activate the environment with `.venv\Scripts\Activate.ps1` on Windows PowerShell or `source .venv/bin/activate` on Linux. Then run:

```sh
python -m pip install -r requirements.txt
python app.py
```

On Linux, the account running the app needs access to the selected serial device. TCP output listens on `127.0.0.1` and supports one receiving client at a time.

## Build and test

Run these commands on the target operating system:

```sh
python -m pip install -r requirements-build.txt
python -m unittest discover -s tests -v
python build.py
```

The executable appears in `dist/`. To rebuild the macOS archive on an Apple Silicon Mac with the Swift toolchain, run `sh macos/build.sh`. The GitHub Actions workflow builds and smoke-tests Windows and Linux and uploads the artifacts for download from the workflow run. The same workflow provides the existing Apple Silicon package. Create a GitHub Release separately if you want to offer persistent download links.

To create a GitHub project, use the contents of this directory as the root of a new repository, including the hidden `.github/` directory. Choose a source license before making the project public. Attach built binaries to the release rather than adding the contents of the ignored `dist/` directory to Git. Publish only this project directory, which contains sample test credentials and no saved caster profiles.

## Credits

The portable decoder uses [pyrtcm](https://github.com/semuconsulting/pyrtcm), serial I/O uses [pySerial](https://github.com/pyserial/pyserial), and executable packaging uses [PyInstaller](https://pyinstaller.org/). The portable basemap is made with [Natural Earth](https://www.naturalearthdata.com/about/terms-of-use/) public-domain 1:110m land data, version 5.1.2. The portable street map uses [OpenStreetMap](https://www.openstreetmap.org/copyright) under its [tile usage policy](https://operations.osmfoundation.org/policies/tiles/).
