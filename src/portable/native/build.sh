#!/bin/sh
set -eu
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-13.0}
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
swiftc -O -parse-as-library -module-cache-path "$stage/cache" \
  "$here/main.swift" "$here/../../macos/BluetoothSPPPort.swift" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$here/Info.plist" \
  -framework IOBluetooth -o "$here/ntripscope-bluetooth"
