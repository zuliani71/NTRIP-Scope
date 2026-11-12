NTRIP Scope Desktop **1.35** for macOS Apple Silicon, Windows x64, Linux ARM64 and Linux x64. Includes command-line client **1.32**.

## Added since the previous public desktop release

- Bidirectional receiver RTCM/GGA via serial/Bluetooth SPP; native macOS HC-06 RFCOMM. Enabled manual rover position takes priority over receiver GGA.
- Separate caster and receiver HEX/ASCII views; live RTCM refresh no longer disrupts message/history selection.
- RTCM Fields, Measurements and C/N₀ tabs; resizable decoder panes and upper-list scrollbar on Windows/Linux.
- Receiver fix quality, source, age and stale/paused indications from checksum-valid GGA.
- Rover from receiver GGA on the map, mountpoint-to-rover distance, preserved zoom and Show both.
- Independent Map & sky and Live stream windows; macOS windows remain visible when focus moves to another application. Correct initial decoder geometry and left alignment.
- Compact header, visible software version, app icon and author/GitHub information. INI import/export; exported passwords omitted.
- CLI 1.32: bidirectional GGA uplink, including native macOS HC-06 RFCOMM, stdout RTCM by default and simultaneous file/TCP/serial outputs.

## Downloads

Choose the archive matching your CPU: macOS ARM64; Windows x64; Linux ARM64 (Ubuntu 24.04-compatible) or Linux x64 (Ubuntu 22.04-compatible). Linux: `uname -m` reports `aarch64` or `x86_64`.

Standalone Windows/Linux CLI executables are inside the desktop archives. macOS CLI is a separate archive. The CLI source ZIP requires Python 3.10+ and its requirements. The complete source tarball includes desktop, CLI and current mobile source. See README and `src/portable/ntripscope.md` for configuration syntax/examples.

## Validation and scope

Recorded native macOS checks and GUI/executable tests on Windows 11, Ubuntu ARM64 and Ubuntu x64 passed. Portable suite: 22 tests (two POSIX-only tests excluded on Windows). Hardware compatibility remains receiver/driver dependent. GPS sky requires RTCM 1019 and GPS MSM; decoded fields vary by platform and message type. These clients do not calculate an RTK solution themselves.

Android is published separately as `android-v0.4.2`. No new iOS binary is included.
