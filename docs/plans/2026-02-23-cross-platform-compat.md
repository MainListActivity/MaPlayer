# Cross-Platform Compatibility Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix five cross-platform issues so the app works correctly on Android, iOS, Linux, Windows, and macOS.

**Architecture:** Purely Dart/config-level changes — no new abstractions, no new files. Each fix is a targeted edit to an existing file. The proxy server already uses `dart:io` `HttpServer` which works on all platforms; we just remove the platform guard. The media_kit platform libs are pub packages that are included at build time per platform automatically.

**Tech Stack:** Flutter / Dart, media_kit, flutter_secure_storage, dart:io HttpServer

---

### Task 1: Add media_kit platform libraries for all targets

**Files:**
- Modify: `pubspec.yaml`

**Step 1: Edit pubspec.yaml — add the four missing platform libs**

In the `dependencies:` section, after `media_kit_libs_macos_video: ^1.1.4`, add:

```yaml
  media_kit_libs_android_video: ^1.0.5
  media_kit_libs_ios_video: ^1.0.5
  media_kit_libs_linux_video: ^1.1.0
  media_kit_libs_windows_video: ^1.0.5
```

**Step 2: Run pub get**

```bash
flutter pub get
```

Expected: resolves all packages without conflict. If version conflicts occur, check pub.dev for the latest compatible versions of each `media_kit_libs_*` package.

**Step 3: Verify analysis is clean**

```bash
flutter analyze --no-fatal-infos
```

Expected: No new errors introduced.

**Step 4: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "feat: add media_kit platform libs for android/ios/linux/windows"
```

---

### Task 2: Enable proxy on all platforms + harden server bind

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

**Context:** `_isSupportedPlatform` at line 31 gates all proxy logic to macOS/Windows only. `dart:io`'s `HttpServer` works on every Dart platform. The server currently binds only to IPv4 loopback; some Android devices prefer IPv6, so we add a fallback.

**Step 1: Remove `_isSupportedPlatform` getter and its early-return branch**

In `ProxyController.createSession()`, find and remove:

```dart
  bool get _isSupportedPlatform => Platform.isMacOS || Platform.isWindows;
```

And inside `createSession()`, remove the early-return block:

```dart
    if (!_isSupportedPlatform) {
      return ResolvedPlaybackEndpoint(
        originalMedia: media,
        playbackUrl: media.url,
      );
    }
```

**Step 2: Harden HttpServer.bind in LocalStreamProxyServer.start()**

Find the current `start()` method in `LocalStreamProxyServer`:

```dart
  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) {
      unawaited(_handle(request));
    });
    logger(
      'local proxy started at ${_server!.address.address}:${_server!.port}',
    );
  }
```

Replace with IPv4-first, IPv6-fallback:

```dart
  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (_) {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
    }
    _server!.listen((request) {
      unawaited(_handle(request));
    });
    logger(
      'local proxy started at ${_server!.address.address}:${_server!.port}',
    );
  }
```

**Step 3: Remove unused dart:io Platform import if it becomes unused**

Check the top of `proxy_controller.dart`. If `Platform` is no longer referenced anywhere in the file after the removal, remove `import 'dart:io';` — but `dart:io` is still used for `HttpServer`, `HttpRequest`, etc., so the import stays. Just confirm no remaining reference to `Platform`.

**Step 4: Verify analysis**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

Expected: No errors or warnings.

**Step 5: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat: enable proxy on all platforms, harden http server bind with ipv6 fallback"
```

---

### Task 3: Fix CredentialStore — use flutter_secure_storage on macOS too

**Files:**
- Modify: `lib/core/security/credential_store.dart`

**Context:** macOS currently falls back to `SharedPreferences` (plaintext `.plist`). `flutter_secure_storage` on macOS uses the system Keychain, which is exactly what we want. The workaround was unnecessary.

**Step 1: Remove the `_useSharedPreferencesOnThisPlatform` getter and all branches that use it**

Current file is 53 lines. Replace the entire file content with:

```dart
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String quarkAuthKey = 'quark_auth_state_v1';

  final FlutterSecureStorage _storage;

  Future<void> writeJson(String key, Map<String, dynamic> value) async {
    await _storage.write(key: key, value: jsonEncode(value));
  }

  Future<Map<String, dynamic>?> readJson(String key) async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    return null;
  }

  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }
}
```

**Step 2: Check if `shared_preferences` is used anywhere else in the codebase**

```bash
grep -r "shared_preferences\|SharedPreferences" lib/
```

If the only usage was in `credential_store.dart`, remove the dependency from `pubspec.yaml` as well (the `shared_preferences: ^2.5.2` line). If used elsewhere, leave it.

**Step 3: Run pub get if pubspec changed**

```bash
flutter pub get
```

**Step 4: Verify analysis**

```bash
flutter analyze lib/core/security/credential_store.dart
```

Expected: No errors.

**Step 5: Commit**

```bash
git add lib/core/security/credential_store.dart pubspec.yaml pubspec.lock
git commit -m "fix: use flutter_secure_storage on all platforms including macOS"
```

---

### Task 4: iOS — declare local network usage in Info.plist

**Files:**
- Modify: `ios/Runner/Info.plist`

**Context:** iOS 14+ blocks apps from binding to the local network without a usage description in Info.plist. Without this, the proxy `HttpServer.bind` will silently fail or the OS will show an undescribed permission dialog.

**Step 1: Add the two required keys to Info.plist**

Open `ios/Runner/Info.plist`. Before the closing `</dict>` tag, add:

```xml
	<key>NSLocalNetworkUsageDescription</key>
	<string>用于本地代理服务器以实现视频分片缓冲播放</string>
	<key>NSBonjourServiceTypes</key>
	<array/>
```

The final lines of the file should look like:

```xml
	<key>UIApplicationSupportsIndirectInputEvents</key>
	<true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>用于本地代理服务器以实现视频分片缓冲播放</string>
	<key>NSBonjourServiceTypes</key>
	<array/>
</dict>
</plist>
```

**Step 2: Verify plist is valid XML**

```bash
plutil -lint ios/Runner/Info.plist
```

Expected: `ios/Runner/Info.plist: OK`

**Step 3: Commit**

```bash
git add ios/Runner/Info.plist
git commit -m "fix: declare NSLocalNetworkUsageDescription for iOS local proxy server"
```

---

### Task 5: Adaptive media_kit buffer size for mobile

**Files:**
- Modify: `lib/features/player/media_kit_player_controller.dart`

**Context:** 256 MB demuxer buffer is appropriate for desktop. On mobile (Android/iOS) it causes memory pressure. 32 MB is sufficient for smooth playback at typical video bitrates.

**Step 1: Add flutter/foundation import and make buffer size platform-adaptive**

Current file:

```dart
import 'package:media_kit/media_kit.dart';

class MediaKitPlayerController {
  MediaKitPlayerController()
    : player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 256 * 1024 * 1024,
        ),
      );
  ...
}
```

Replace with:

```dart
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

class MediaKitPlayerController {
  MediaKitPlayerController()
    : player = Player(
        configuration: PlayerConfiguration(
          bufferSize: defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS
              ? 32 * 1024 * 1024
              : 256 * 1024 * 1024,
        ),
      );

  final Player player;

  Future<void> open(String url, {Map<String, String>? headers}) async {
    final configuration = Media(
      url,
      httpHeaders: (headers != null && headers.isNotEmpty) ? headers : null,
    );
    await player.open(configuration);
  }

  Future<void> dispose() => player.dispose();
}
```

Note: `PlayerConfiguration` constructor call changes from `const` to non-const because the buffer size is now computed at runtime.

**Step 2: Verify analysis**

```bash
flutter analyze lib/features/player/media_kit_player_controller.dart
```

Expected: No errors.

**Step 3: Commit**

```bash
git add lib/features/player/media_kit_player_controller.dart
git commit -m "fix: use 32MB buffer on mobile, 256MB on desktop"
```

---

## Final Verification

After all five tasks:

```bash
flutter analyze --no-fatal-infos
```

Expected: Clean (or same pre-existing warnings as before).

Check each target builds without error:

```bash
flutter build apk --debug          # Android
flutter build ios --debug --no-codesign  # iOS (requires macOS)
flutter build linux --debug        # Linux
flutter build windows --debug      # Windows
flutter build macos --debug        # macOS
```
