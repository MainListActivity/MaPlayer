# Cross-Platform Compatibility Design

**Date:** 2026-02-23
**Scope:** Android / iOS / Linux / Windows / macOS

## Background

The app needs to deploy to all platforms. Besides the Spider system (already removed via webview+JS), the following issues were identified and approved for fixing.

## Problems & Approved Solutions

### Fix 1 — media_kit platform libraries (CRITICAL)

`pubspec.yaml` only has `media_kit_libs_macos_video`. Without the other platform libs, video playback is broken on every non-macOS target.

**Solution:** Add all missing platform libs:
- `media_kit_libs_android_video`
- `media_kit_libs_ios_video`
- `media_kit_libs_linux_video`
- `media_kit_libs_windows_video`

### Fix 2 — Proxy server enabled on all platforms

`proxy_controller.dart` has `_isSupportedPlatform => Platform.isMacOS || Platform.isWindows`, meaning Android/iOS/Linux skip the chunked-download proxy entirely and play via direct URL.

**Solution:** Remove the platform guard. `dart:io`'s `HttpServer` works on all platforms. Also harden the server bind to try IPv4 loopback first, then fall back to IPv6 loopback, for Android devices that prefer IPv6.

### Fix 3 — CredentialStore: macOS uses plaintext SharedPreferences

On macOS, credentials are stored via `SharedPreferences` (plaintext plist). Other platforms use `flutter_secure_storage` (Keychain/Keystore).

**Solution:** Remove the `_useSharedPreferencesOnThisPlatform` branch. `flutter_secure_storage` on macOS uses the system Keychain — it works correctly without extra config.

### Fix 4 — iOS local network permission declaration

iOS 14+ requires `NSLocalNetworkUsageDescription` in `Info.plist` for any app that binds a local HTTP server. Without it, the OS silently blocks the loopback bind prompt.

**Solution:** Add `NSLocalNetworkUsageDescription` (and empty `NSBonjourServiceTypes`) to `ios/Runner/Info.plist`.

### Fix 5 — media_kit buffer size adaptive for mobile

The player is configured with a fixed 256 MB demuxer buffer. On low-end Android/iOS devices this causes memory pressure.

**Solution:** Use 32 MB on mobile platforms, keep 256 MB on desktop.

## Files to Change

| File | Change |
|------|--------|
| `pubspec.yaml` | Add 4 media_kit platform lib deps |
| `lib/features/player/proxy/proxy_controller.dart` | Remove `_isSupportedPlatform` guard; harden server bind |
| `lib/core/security/credential_store.dart` | Remove SharedPreferences branch for macOS |
| `ios/Runner/Info.plist` | Add `NSLocalNetworkUsageDescription` |
| `lib/features/player/media_kit_player_controller.dart` | Adaptive buffer size by platform |
