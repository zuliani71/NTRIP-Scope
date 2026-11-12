#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
python3 - "$here/../NTRIP.swift" "$here/StreamMonitorSnapshotTests.swift" "$stage" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text().replace('\n@main\n','\n')
s+='\nextension Radio { func fixtureReceive(_ data: Data) { rtcm.receive(data) } }\n'
s+='\n@MainActor func fixtureDecoder(_ radio: Radio) -> some View { RTCMStreamMonitor(radio: radio, active: true) }\n'
Path(sys.argv[3]+'/App.swift').write_text(s)
f=Path(sys.argv[2]).read_text().split('@main struct MonitorCheck {',1)[1].split('    @MainActor static func main()',1)[0]
Path(sys.argv[3]+'/Fixture.swift').write_text('import Foundation\nenum Fixture {\n'+f+'\n}')
PY
swiftc -parse-as-library -module-cache-path "$stage/cache" \
  "$here/../Language.swift" "$here/../RTCMDecoder.swift" "$here/../StationSky.swift" \
  "$here/../BluetoothSPPPort.swift" "$here/../WindowLayout.swift" "$here/../SerialPort.swift" \
  "$here/../StreamMonitorSnapshot.swift" "$here/../NMEAGGA.swift" "$here/../RoverPosition.swift" \
  "$here/../INIConfiguration.swift" "$stage/App.swift" "$stage/Fixture.swift" \
  "$here/DecoderWindowTests.swift" -o "$stage/layout-check"
"$stage/layout-check"
