#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
app='NTRIP Scope - RTCM Decoder.app'

mkdir -p "$stage/$app/Contents/MacOS" "$stage/$app/Contents/Resources"
cp "$here/Info.plist" "$stage/$app/Contents/Info.plist"
cp "$here/Orbit.icns" "$stage/$app/Contents/Resources/Orbit.icns"
cp "$here/../assets/land.json" "$stage/$app/Contents/Resources/land.json"
swiftc -parse-as-library -O -target arm64-apple-macos13.0 -module-cache-path "$stage/module-cache" \
  "$here/Language.swift" "$here/RTCMDecoder.swift" "$here/StationSky.swift" \
  "$here/RoverPosition.swift" "$here/NTRIP.swift" \
  -o "$stage/$app/Contents/MacOS/NTRIPRadio"
codesign --force --sign - "$stage/$app"
codesign --verify --strict "$stage/$app"

out="$here/../dist"
mkdir -p "$out"
ditto -c -k --keepParent "$stage/$app" "$out/NTRIP-Scope-macos-arm64.zip"
printf '%s\n' "$out/NTRIP-Scope-macos-arm64.zip"
