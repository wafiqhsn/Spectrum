# Privacy and data flow

- **Audio:** captured from selected Spotify processes through Core Audio Process Tap, held in a bounded memory buffer, and analyzed locally. Spectrum does not record audio files or upload captured samples.
- **Spotify controls:** macOS Automation reads track information and controls playback. This requires permission separate from audio recording permission.
- **Lyrics:** only when enabled, Spectrum requests LRCLIB lyrics using the track title, artist, album, and duration. Synced/plain results are cached in memory, with a limit of 40 track entries. HTTPS requests can also use the operating system's URL cache.
- **Artwork:** when enabled, the current artwork is downloaded from an HTTPS URL supplied by Spotify. The operating system may cache downloaded responses on disk.
- **Preferences:** settings use macOS UserDefaults. No user account or application analytics service is implemented.
- **Permissions:** macOS manages recording and Automation access. Disabling a feature does not revoke its system permission; permissions can be reviewed in System Settings → Privacy & Security.

Capture and FFT pause when no visualizer is visible. Playback metadata continues to refresh more slowly when both players are hidden. Prevent Sleep is a separate explicit feature and resets on quit.

This describes the source in this repository; Spotify, LRCLIB, macOS, and GitHub have their own policies.
