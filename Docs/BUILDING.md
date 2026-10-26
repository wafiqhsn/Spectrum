# Building Spectrum

## Xcode

Open `Spectrum.xcodeproj`, choose the shared `Spectrum` scheme, and select My Mac. Development builds use ad-hoc signing by default. If macOS requests Automation or System Audio Recording permission, grant only the permissions you want to use.

Use an Xcode installation with a macOS SDK supporting Core Audio Process Taps. The deployment target is macOS 14.2. Xcode 26.2 is the locally validated toolchain.

## Command line

```sh
bash Scripts/build.sh
bash Tests/run.sh
```

If the selected developer directory is Command Line Tools rather than full Xcode, select Xcode for this command without changing the system-wide setting:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Scripts/build.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/run.sh
```

The build is unsigned, Release, and universal (`arm64` and `x86_64`). Output:

```text
build/DerivedData/Build/Products/Release/Spectrum.app
```

`bash Scripts/package.sh` builds and wraps that unsigned app in `build/Spectrum-macOS-unsigned.zip`. It does not sign, notarize, upload, or create a GitHub release.

## Checks

The checks run offline and do not start a real Spotify audio tap or contact LRCLIB:

- Silence handling, FFT frequency peaks/amplitude across sample rates, stereo channel extraction, frame counting.
- LRC timestamps, ordering, offsets, active-line lookup, and malformed input.
- FFT/VU updates during menu tracking, suspension/resume, deferred start, and explicit Stop.

CI builds the app and runs these checks on macOS. It does not grant macOS recording/Automation permissions or certify live capture, UI behavior, signing, or battery life.

## Manual smoke check

Play Spotify, verify Automation controls and the capture status, try each visualizer and Lyrics, then Close/reopen, Minimize/restore, and Quit. When no visualizer is visible, capture should be released. A system-wide “Minimize windows into application icon” setting can hide separate Dock thumbnails.

## Bundle identity

The internal bundle identifier remains `dev.local.SpotifySpectrum` for continuity with existing local installations. For independent distribution, configure your own identifier, signing team, entitlements, and privacy descriptions. The project does not contain a developer certificate, private key, API key, or signing team ID.
