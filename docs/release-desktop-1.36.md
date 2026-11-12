# NTRIP Scope Desktop 1.36 · CLI 1.32

Desktop packages for macOS ARM64, Windows x64, Linux ARM64 and Linux x64.

## New in 1.36

- Mountpoint information below the map now includes the selected mountpoint name.
- Rover information includes receiver GGA fix quality, source and age, with STALE/PAUSED states and the manual-coordinate priority note.
- NO FIX remains visible even when no valid rover coordinates are available. Manual coordinates do not create an artificial RTK status.

All 1.35 functionality is retained: independent desktop windows, stable RTCM history, Fields/Measurements/C/N₀, separate receiver/caster streams, bidirectional GGA, INI configuration, maps and GPS sky. CLI remains 1.32.

## Packages and validation

Choose your CPU architecture, or download the combined desktop ZIP. The complete source tarball and CLI source ZIP are included. macOS requires Apple Silicon/macOS 13+. Linux ARM64 targets Ubuntu 24.04-compatible systems; Linux x64 targets Ubuntu 22.04-compatible systems. Windows/Linux archives include standalone CLI 1.32; macOS CLI is a separate ZIP.

Recorded checks: macOS build and real map layout inspection; native decoder layout test; 22 portable tests (two POSIX-only exclusions on Windows), GUI and executable smoke checks on Windows 11, Ubuntu ARM64 and Ubuntu x64. GUI checks cover mountpoint name, RTK FIXED, NO FIX, PAUSED and manual-GGA information in the map. No new physical-radio test in this change.
