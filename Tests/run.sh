#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$root/.build/Tests"
mkdir -p "$build_dir/ModuleCache"
common=(-O -swift-version 5 -warnings-as-errors -module-cache-path "$build_dir/ModuleCache")
xcrun swiftc "${common[@]}"   "$root/Spectrum/SpectrumFFT.swift" "$root/Spectrum/AudioCapture.swift" "$root/Tests/SignalChecks.swift"   -o "$build_dir/SignalChecks" -framework Accelerate -framework CoreAudio -framework AppKit
"$build_dir/SignalChecks"
xcrun swiftc "${common[@]}"   "$root/Spectrum/Lyrics.swift" "$root/Tests/LyricsChecks.swift"   -o "$build_dir/LyricsChecks" -framework SwiftUI
"$build_dir/LyricsChecks"
xcrun swiftc "${common[@]}"   "$root/Spectrum/SpectrumModel.swift" "$root/Spectrum/SpectrumFFT.swift" "$root/Spectrum/AudioCapture.swift" "$root/Tests/MenuTrackingChecks.swift"   -o "$build_dir/MenuTrackingChecks" -framework SwiftUI -framework CoreAudio -framework Accelerate
"$build_dir/MenuTrackingChecks"
