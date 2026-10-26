#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$root/Scripts/build.sh"
app="$root/build/DerivedData/Build/Products/Release/Spectrum.app"
archive="$root/build/Spectrum-macOS-unsigned.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
printf 'Unsigned development archive: %s\n' "$archive"
