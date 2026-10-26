# Release preparation

This repository publishes source. It does not imply that a public, signed application release is ready.

Before distributing a downloadable app:

1. Select the intended source/asset/distribution license. No license is currently assigned to this repository.
2. Review the rights and terms applicable to lyric display, Spotify-provided artwork/metadata, and developer branding.
3. Set the distribution bundle identifier and Apple signing identity. The legacy local identifier is retained only for development continuity.
4. Build and test the supported macOS versions and CPU architectures, including live capture, permissions, playback, and output-device changes.
5. Prepare Developer ID signing, hardened runtime, notarization, and stapling (or the appropriate App Store route). The provided packaging script only produces an unsigned development ZIP.
6. Confirm permission descriptions, privacy documentation, credits, version numbers, and upgrade behavior.
7. Publish app binaries as intentional release assets, not as tracked `.app` folders in the source repository.

## References

- LRCLIB API: https://lrclib.net/docs
- LRCLIB server license: https://github.com/tranxuanthang/lrclib/blob/main/LICENSE
- Spotify integration guidelines: https://developer.spotify.com/documentation/design
- Apple distribution documentation: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

LRCLIB's server software license is distinct from lyric rights. About notices are credits, not endorsement or distribution clearance.
