# Chunk-Level LRU & Playback Progress Persistence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give `_ProxySession` a chunk-level LRU cap so downloaded-chunk metadata stays accurate after eviction, and persist `_playbackOffset` to disk so `PlayerPage` can seek to the last-watched position on next open.

**Architecture:** Chunk LRU is handled entirely inside `_ProxySession` using a `LinkedHashMap` for access-order tracking; eviction removes chunk indices from `_downloadedChunks` (no disk erasure). Progress is written to the existing `.json` sidecar at dispose time and read back in `initialize()`; `ProxyController` exposes a single getter; `PlayerPage` does a linear byte→duration seek after the player opens.

**Tech Stack:** Dart, Flutter, media_kit

---

## Task 1: Thread `maxCacheBytes` into `_ProxySession` and compute `_maxChunks`

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

### Step 1: Add `maxCacheBytes` constructor parameter to `_ProxySession`

Find the `_ProxySession` constructor (line ~386). Add the parameter after `maxOpenEndedResponseBytes`:

```dart
// existing params end ...
required this.maxOpenEndedResponseBytes,
required this.maxCacheBytes,          // ← add
```

And the corresponding field at the top of the class (after `maxOpenEndedResponseBytes`):

```dart
final int maxOpenEndedResponseBytes;
final int maxCacheBytes;               // ← add
```

### Step 2: Add `_maxChunks` field and compute it in `initialize()`

Add the field declaration (near `_activeWorkers`):

```dart
late final int _maxChunks;
```

At the **start** of `initialize()`, before the meta-read block:

```dart
_maxChunks = (maxCacheBytes / chunkSize).floor().clamp(16, 1024);
```

### Step 3: Pass `maxCacheBytes` from `ProxyController.createSession()`

In `createSession()`, find the `_ProxySession(...)` constructor call (~line 93). Add:

```dart
maxCacheBytes: _maxCacheBytes,
```

### Step 4: Verify it compiles

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

Expected: no errors.

### Step 5: Commit

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat: thread maxCacheBytes into _ProxySession, compute _maxChunks"
```

---

## Task 2: Add `_chunkAccessOrder` LRU map and `_touchChunk` / `_evictChunksIfNeeded`

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

### Step 1: Add the `_chunkAccessOrder` field

Next to `_downloadedChunks` and `_chunkBuffer` declarations (~line 425):

```dart
// LRU tracking: key = chunk index, value = last-access epoch-ms.
// LinkedHashMap preserves insertion order → head = oldest.
final LinkedHashMap<int, int> _chunkAccessOrder = LinkedHashMap();
```

(`LinkedHashMap` is already imported via `dart:collection`.)

### Step 2: Add `_touchChunk`

After `_countCachedChunksInRange` method (~line 991):

```dart
void _touchChunk(int chunkIndex) {
  _chunkAccessOrder.remove(chunkIndex);
  _chunkAccessOrder[chunkIndex] = DateTime.now().millisecondsSinceEpoch;
}
```

### Step 3: Add `_evictChunksIfNeeded`

Directly after `_touchChunk`:

```dart
void _evictChunksIfNeeded() {
  while (_downloadedChunks.length > _maxChunks) {
    final oldest = _chunkAccessOrder.keys.first;
    _downloadedChunks.remove(oldest);
    _chunkBuffer.remove(oldest);
    _chunkAccessOrder.remove(oldest);
  }
}
```

### Step 4: Verify compile

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

Expected: no errors.

### Step 5: Commit

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat: add _chunkAccessOrder LRU map, _touchChunk and _evictChunksIfNeeded"
```

---

## Task 3: Wire `_touchChunk` and `_evictChunksIfNeeded` into prefetch and serve paths

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

### Step 1: Touch + evict after chunk download in `_startPrefetch`

In `_startPrefetch`, find the block after `_downloadedChunks.add(chunkIndex)` (~line 1174):

```dart
_downloadedChunks.add(chunkIndex);
```

Immediately after that line add:

```dart
_touchChunk(chunkIndex);
_evictChunksIfNeeded();
```

### Step 2: Touch on read in `_serveParallel`

In `_serveParallel`, inside the `while (offset <= end)` loop, right after `final chunkIndex = offset ~/ chunkSize;` (~line 884):

```dart
final chunkIndex = offset ~/ chunkSize;
_touchChunk(chunkIndex);   // ← add
```

### Step 3: Also remove evicted chunks from `_chunkAccessOrder` on warm-cache restore

In `initialize()`, after `_downloadedChunks.addAll(cachedChunks)` (~line 511):

```dart
_downloadedChunks.addAll(cachedChunks);
// Seed access-order map with restored chunks (all treated as equally old).
for (final idx in cachedChunks) {
  _chunkAccessOrder[idx] = 0; // epoch 0 = oldest possible
}
```

This ensures that restored-but-LRU-eligible chunks are candidates for eviction on first overflow.

### Step 4: Verify compile

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

Expected: no errors.

### Step 5: Commit

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat: wire _touchChunk and _evictChunksIfNeeded into prefetch and serve"
```

---

## Task 4: Persist `lastPlaybackPosition` in `.json` and restore it in `initialize()`

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

### Step 1: Add `_restoredPlaybackPosition` field to `_ProxySession`

Next to `_playbackOffset` (~line 447):

```dart
int? _restoredPlaybackPosition;
```

### Step 2: Read `lastPlaybackPosition` from `.json` in `initialize()`

In `initialize()`, inside the `try` block that parses the cached meta map, after the `cachedChunks` parsing:

```dart
final rawPos = map['lastPlaybackPosition'];
if (rawPos is int) {
  _restoredPlaybackPosition = rawPos;
}
```

### Step 3: Write `lastPlaybackPosition` to `.json` in `_writeMeta()`

In `_writeMeta()`, add to the `payload` map (~line 1088):

```dart
'lastPlaybackPosition': _playbackOffset,
```

### Step 4: Expose a getter on `_ProxySession`

After the `descriptor` getter (~line 465):

```dart
int? get restoredPlaybackPosition => _restoredPlaybackPosition;
```

### Step 5: Expose `getRestoredPosition` on `ProxyController`

After `watchStats` method (~line 119):

```dart
/// Returns the byte offset of the last known playback position for
/// [sessionId], or null if no position has been saved.
int? getRestoredPosition(String sessionId) =>
    _sessions[sessionId]?.restoredPlaybackPosition;
```

### Step 6: Verify compile

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

Expected: no errors.

### Step 7: Commit

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat: persist lastPlaybackPosition in session .json, expose getRestoredPosition"
```

---

## Task 5: Add `contentLength` to `ProxySessionDescriptor`

**Files:**
- Modify: `lib/features/player/proxy/proxy_models.dart`
- Modify: `lib/features/player/proxy/proxy_controller.dart`

### Step 1: Add `contentLength` field to `ProxySessionDescriptor`

In `proxy_models.dart`, update the class:

```dart
class ProxySessionDescriptor {
  const ProxySessionDescriptor({
    required this.sessionId,
    required this.sourceUrl,
    required this.headers,
    required this.mode,
    required this.createdAt,
    this.contentLength,          // ← add (nullable; unknown until probe)
  });

  final String sessionId;
  final String sourceUrl;
  final Map<String, String> headers;
  final ProxyMode mode;
  final DateTime createdAt;
  final int? contentLength;      // ← add
}
```

### Step 2: Pass `contentLength` from `_ProxySession.descriptor` getter

In `proxy_controller.dart`, update the `descriptor` getter (~line 465):

```dart
ProxySessionDescriptor get descriptor => ProxySessionDescriptor(
  sessionId: sessionId,
  sourceUrl: sourceUrl,
  headers: headers,
  mode: _mode,
  createdAt: createdAt,
  contentLength: _contentLength,   // ← add
);
```

### Step 3: Verify compile

```bash
flutter analyze lib/features/player/proxy/
```

Expected: no errors.

### Step 4: Commit

```bash
git add lib/features/player/proxy/proxy_models.dart \
        lib/features/player/proxy/proxy_controller.dart
git commit -m "feat: expose contentLength on ProxySessionDescriptor"
```

---

## Task 6: Seek to restored position in `PlayerPage` after open

**Files:**
- Modify: `lib/features/player/player_page.dart`

### Step 1: Add `_waitForDuration` helper to `_PlayerPageState`

Add this private method to the class (e.g. below `_bindProxyStats`):

```dart
/// Waits for media_kit to report a non-zero duration, up to [timeout].
/// Returns Duration.zero on timeout.
Future<Duration> _waitForDuration({
  Duration timeout = const Duration(seconds: 5),
}) async {
  final current = _playerController.player.state.duration;
  if (current > Duration.zero) return current;
  final completer = Completer<Duration>();
  late StreamSubscription<Duration> sub;
  sub = _playerController.player.stream.duration.listen((d) {
    if (d > Duration.zero) {
      sub.cancel();
      if (!completer.isCompleted) completer.complete(d);
    }
  });
  Future<void>.delayed(timeout).then((_) {
    sub.cancel();
    if (!completer.isCompleted) completer.complete(Duration.zero);
  });
  return completer.future;
}
```

### Step 2: Add seek-to-restored-position call in `_openMedia`

In `_openMedia`, after `await _playerController.open(endpoint.playbackUrl, headers: playHeaders);` and before the `if (prevSessionId != null ...)` block:

```dart
// Seek to restored playback position if available.
final restoredBytes = currentSessionId != null
    ? ProxyController.instance.getRestoredPosition(currentSessionId)
    : null;
if (restoredBytes != null && restoredBytes > 0) {
  final contentLength = endpoint.proxySession?.contentLength;
  if (contentLength != null && contentLength > 0) {
    final duration = await _waitForDuration();
    if (duration > Duration.zero) {
      final seekFraction = restoredBytes / contentLength;
      final seekTo = duration * seekFraction;
      await _playerController.player.seek(seekTo);
    }
  }
}
```

### Step 3: Add missing `dart:async` import if not present

Check the top of `player_page.dart` — `dart:async` is already imported (line 1). No action needed.

### Step 4: Verify compile

```bash
flutter analyze lib/features/player/player_page.dart
```

Expected: no errors.

### Step 5: Commit

```bash
git add lib/features/player/player_page.dart
git commit -m "feat: seek to restored playback position on open"
```

---

## Task 7: Manual smoke test

These are not automated (no test harness for the proxy layer exists yet); verify manually:

1. **LRU eviction:**
   - Temporarily lower `_maxCacheBytes` to a very small value (e.g. `4 * 1024 * 1024` = 4 MB → `_maxChunks = 2`) to force rapid eviction.
   - Play a file, observe in logs that `_downloadedChunks` stays ≤ 2 entries.
   - Seek forward — previously-evicted chunks should be re-downloaded without crash.
   - Restore `_maxCacheBytes` to `2 * 1024 * 1024 * 1024`.

2. **Progress persistence:**
   - Play a file, advance to ~30 s.
   - Close the player (triggers `dispose` → `_writeMeta`).
   - Reopen the same file.
   - Confirm playback resumes near the 30 s mark.
   - Check the `.json` sidecar contains `"lastPlaybackPosition": <non-zero>`.

3. **Cold start (no prior session):**
   - Delete the `.json` sidecar for the session.
   - Open the file — should start from the beginning without crash.

### Commit after verifying

```bash
git commit --allow-empty -m "chore: manual smoke test passed for LRU and progress restore"
```
