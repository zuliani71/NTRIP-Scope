#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
swiftc -parse-as-library -module-cache-path "$stage/module-cache" \
    "$here/../Language.swift" "$here/../RTCMDecoder.swift" "$here/../StationSky.swift" \
    "$here/../BluetoothSPPPort.swift" "$here/../WindowLayout.swift" "$here/WindowLayoutTests.swift" "$here/../SerialPort.swift" "$here/SerialPortTests.swift" "$here/../NMEAGGA.swift" "$here/RoverMapTests.swift" "$here/../StreamMonitorSnapshot.swift" "$here/StreamMonitorSnapshotTests.swift" \
    -o "$stage/monitor-check"
"$stage/monitor-check"
