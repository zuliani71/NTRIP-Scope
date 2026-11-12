#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
# Test the actual Radio implementation without launching the production app.
python3 - "$here/../NTRIP.swift" "$stage/Radio.swift" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text(s[:s.index('\nstruct ',s.index('final class Radio'))])
PY
swiftc -parse-as-library -module-cache-path "$stage/module-cache" \
    "$here/../Language.swift" "$here/../RTCMDecoder.swift" "$here/../StationSky.swift" \
    "$here/../RoverPosition.swift" "$here/../NMEAGGA.swift" \
    "$here/../SerialPort.swift" "$here/../BluetoothSPPPort.swift" \
    "$stage/Radio.swift" "$here/RadioSessionTests.swift" -o "$stage/session-check"
"$stage/session-check"
