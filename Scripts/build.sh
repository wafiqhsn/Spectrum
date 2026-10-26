#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
xcrun xcodebuild   -project "$root/Spectrum.xcodeproj"   -scheme Spectrum   -configuration Release   -destination 'generic/platform=macOS'   -derivedDataPath "$root/build/DerivedData"   CODE_SIGNING_ALLOWED=NO   'ARCHS=arm64 x86_64'   ONLY_ACTIVE_ARCH=NO   build
