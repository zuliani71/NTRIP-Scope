#!/bin/bash
set -e
cd "$(dirname "$0")"
if command -v flutter >/dev/null 2>&1; then
  ntrip_flutter=$(command -v flutter)
elif [ -n "${FLUTTER_ROOT:-}" ] && [ -x "$FLUTTER_ROOT/bin/flutter" ]; then
  ntrip_flutter="$FLUTTER_ROOT/bin/flutter"
else
  echo 'Flutter not found. Install Flutter and add its bin directory to PATH, or set FLUTTER_ROOT.'
  read -r -p 'Press Return to close.'
  exit 1
fi
export BYPASS_PERMISSION_LOCATION_ALWAYS=1
"$ntrip_flutter" pub get
"$ntrip_flutter" build ios --debug --config-only --no-codesign
open ios/Runner.xcworkspace
echo 'In Xcode: Runner > Signing & Capabilities > Team; select your iPhone/iPad, then Run.'
