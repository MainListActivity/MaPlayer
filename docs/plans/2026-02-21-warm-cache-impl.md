# Warm-Cache Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restore downloaded chunk indices from disk on session init so the same video is never re-downloaded when reopened.

**Architecture:** Extend the existing `.json` sidecar to store a `downloadedChunks` array. On `initialize()`, load that array, probe the remote `contentLength`, and open `.bin` in append mode if lengths match (invalidate and recreate on mismatch). A debounced 5-second timer writes meta after each `_persistChunk()` call so progress survives most crashes.

**Tech Stack:** Dart / Flutter, `dart:io` (File, RandomAccessFile, Timer), `dart:convert` (jsonDecode/jsonEncode).

---

### Task 1: Add `_metaDebounceTimer` field and helper to `_ProxySession`

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

**Context:**
`_ProxySession` already has a `Timer? _statsTimer` field (line 348). We add a second timer for debounced meta writes. The class already imports `dart:async` and `dart:io`.

**Step 1: Add the timer field**

In `_ProxySession`, after the `Timer? _statsTimer;` field (line 348), add:

```dart
Timer? _metaDebounceTimer;
```

**Step 2: Add `_scheduleMeta()` helper method**

Add this private method anywhere inside `_ProxySession` (e.g. right after `_writeMeta()`):

```dart
void _scheduleMeta() {
  _metaDebounceTimer?.cancel();
  _metaDebounceTimer = Timer(const Duration(seconds: 5), () {
    unawaited(_writeMeta());
  });
}
```

**Step 3: Verify the file compiles**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

Expected: no new errors.

**Step 4: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat(proxy): add debounced meta-write timer field and helper"
```

---

### Task 2: Update `_writeMeta()` to persist `downloadedChunks` array

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart:759-775`

**Context:**
Current `_writeMeta()` writes `downloadedChunkCount` (an int). We add `downloadedChunks` (a sorted list of chunk indices) so it can be restored on next session init.

**Step 1: Replace the payload map inside `_writeMeta()`**

Find (lines 761–770):
```dart
      final payload = <String, dynamic>{
        'sessionId': sessionId,
        'sourceUrl': sourceUrl,
        'mode': _mode.name,
        'createdAt': createdAt.toIso8601String(),
        'lastAccessAt': _lastAccessAt.toIso8601String(),
        'contentLength': _contentLength,
        'downloadedChunkCount': _downloadedChunks.length,
        'degradeReason': _degradeReason,
      };
```

Replace with:
```dart
      final payload = <String, dynamic>{
        'sessionId': sessionId,
        'sourceUrl': sourceUrl,
        'mode': _mode.name,
        'createdAt': createdAt.toIso8601String(),
        'lastAccessAt': _lastAccessAt.toIso8601String(),
        'contentLength': _contentLength,
        'downloadedChunks': (_downloadedChunks.toList()..sort()),
        'downloadedChunkCount': _downloadedChunks.length,
        'degradeReason': _degradeReason,
      };
```

**Step 2: Verify**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

Expected: no errors.

**Step 3: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat(proxy): persist downloadedChunks index list in meta JSON"
```

---

### Task 3: Call `_scheduleMeta()` from `_persistChunk()`

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart:732-748`

**Context:**
`_persistChunk()` currently writes data to disk and removes the chunk from `_chunkBuffer`. After the write succeeds we trigger the debounced meta update so chunk indices are checkpointed within 5 s.

**Step 1: Add `_scheduleMeta()` call after the write lock is released**

Find the `_persistChunk` method. Its `finally` block currently is:
```dart
    } finally {
      _writeLock.release();
      _chunkBuffer.remove(chunkIndex);
    }
```

Replace with:
```dart
    } finally {
      _writeLock.release();
      _chunkBuffer.remove(chunkIndex);
      _scheduleMeta();
    }
```

**Step 2: Verify**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

**Step 3: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat(proxy): schedule debounced meta write after each chunk persist"
```

---

### Task 4: Cancel `_metaDebounceTimer` and flush meta in `dispose()`

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart:466-490`

**Context:**
`dispose()` already cancels `_statsTimer` and calls `_writeMeta()` at the end. We must also cancel the debounce timer (so it doesn't fire on a disposed object) before the final synchronous meta write.

**Step 1: Cancel the debounce timer**

In `dispose()`, find:
```dart
    _statsTimer?.cancel();
```

Add the cancellation immediately after:
```dart
    _statsTimer?.cancel();
    _metaDebounceTimer?.cancel();
```

**Step 2: Verify**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

**Step 3: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat(proxy): cancel meta debounce timer on dispose"
```

---

### Task 5: Load cached chunk indices in `initialize()` and validate against remote

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart:380-418`

**Context:**
This is the core warm-cache logic. Current `initialize()`:
1. Creates `.bin` if missing.
2. Opens `.bin` with `FileMode.write` (truncates).
3. Probes remote.

New flow:
1. Read `.json` if it exists → extract `cachedContentLength` and `cachedChunks`.
2. Probe remote.
3. If probe succeeds and lengths match → open `.bin` with `FileMode.writeOnlyAppend`, restore `_downloadedChunks`.
4. If mismatch (or no cache) → delete stale `.bin`/`.json`, open fresh `.bin` with `FileMode.write`.

**Step 1: Replace `initialize()` body**

Find the entire `initialize()` method (lines 380–419) and replace with:

```dart
  Future<void> initialize() async {
    _cacheFile = File('${cacheRoot.path}/$sessionId.bin');
    _metaFile = File('${cacheRoot.path}/$sessionId.json');

    // --- Read cached meta (best effort) ---
    int? cachedContentLength;
    List<int> cachedChunks = const [];
    if (await _metaFile.exists()) {
      try {
        final raw = await _metaFile.readAsString();
        final map = jsonDecode(raw) as Map<String, dynamic>;
        cachedContentLength = map['contentLength'] as int?;
        final chunksRaw = map['downloadedChunks'];
        if (chunksRaw is List) {
          cachedChunks = chunksRaw.cast<int>();
        }
      } catch (_) {
        // Corrupt meta — treat as cold start.
        cachedContentLength = null;
        cachedChunks = const [];
      }
    }

    // --- Probe remote ---
    final probe = await _probeRangeSupport();
    _contentLength = probe.contentLength;
    _contentType = probe.contentType;

    // --- Warm-cache: validate and restore ---
    final canWarm = cachedContentLength != null &&
        _contentLength != null &&
        cachedContentLength == _contentLength &&
        cachedChunks.isNotEmpty &&
        await _cacheFile.exists();

    if (canWarm) {
      // Open in append mode — does NOT truncate existing data.
      _writeRaf = await _cacheFile.open(mode: FileMode.writeOnlyAppend);
      _downloadedChunks.addAll(cachedChunks);
      logger(
        'session=$sessionId warm-cache restored '
        '${cachedChunks.length} chunks (contentLength=$_contentLength)',
      );
    } else {
      // Invalidate stale cache files if they exist.
      if (await _cacheFile.exists()) {
        try { await _cacheFile.delete(); } catch (_) {}
      }
      if (await _metaFile.exists()) {
        try { await _metaFile.delete(); } catch (_) {}
      }
      await _cacheFile.create(recursive: true);
      _writeRaf = await _cacheFile.open(mode: FileMode.write);
      if (cachedContentLength != null &&
          _contentLength != null &&
          cachedContentLength != _contentLength) {
        logger(
          'session=$sessionId cache invalidated: '
          'cachedLength=$cachedContentLength remoteLength=$_contentLength',
        );
      }
    }

    if (!probe.supportsRange ||
        _contentLength == null ||
        _contentLength! <= 0) {
      _degradeToSingle(
        'range unsupported or unknown content length '
        '(supportsRange=${probe.supportsRange}, len=${probe.contentLength})',
      );
    }
    _statsLastSampleAt = DateTime.now();
    _downloadBytesLastSample = _downloadBytesTotal;
    _serveBytesLastSample = _serveBytesTotal;

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_statsController.isClosed) return;
      final now = DateTime.now();
      final elapsedMs = max(1, now.difference(_statsLastSampleAt).inMilliseconds);
      final downloadDelta = _downloadBytesTotal - _downloadBytesLastSample;
      final serveDelta = _serveBytesTotal - _serveBytesLastSample;
      final snapshot = ProxyStatsSnapshot(
        sessionId: sessionId,
        downloadBps: downloadDelta * 8000.0 / elapsedMs,
        serveBps: serveDelta * 8000.0 / elapsedMs,
        cacheHitRate: _requestedBytes <= 0
            ? 0
            : _cacheHitBytes / _requestedBytes,
        activeWorkers: _activeWorkers,
        bufferedBytesAhead: _bufferedBytesAhead(),
        mode: _mode,
        updatedAt: now,
      );
      _statsLastSampleAt = now;
      _downloadBytesLastSample = _downloadBytesTotal;
      _serveBytesLastSample = _serveBytesTotal;
      if (!_statsController.isClosed) {
        _statsController.add(snapshot);
      }
    });
  }
```

**Step 2: Verify**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

Expected: no errors. If `jsonDecode` is flagged, confirm `dart:convert` is already imported at line 3 (it is).

**Step 3: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat(proxy): restore warm-cache from disk on session init"
```

---

### Task 6: Manual smoke test

**No code changes in this task.**

**Step 1: Run the app and open a video**

Note which chunks are downloading in the proxy stats overlay.

**Step 2: Let it buffer ~10 chunks, then close the player**

The debounce timer fires within 5 s; dispose() writes the final meta. Check the JSON file:

```bash
cat ~/Library/Caches/ma_player/proxy_cache/*.json
```

Expected: `downloadedChunks` is a non-empty sorted array.

**Step 3: Reopen the same video**

Watch the proxy stats. The log should print:
```
[proxy] session=<id> warm-cache restored N chunks (contentLength=...)
```

And `cacheHitRate` should be non-zero from the start.

**Step 4: Verify seek still works**

Seek to a position whose chunk is already cached — it should serve instantly (no network request for that chunk).

**Step 5: Verify invalidation**

Manually edit the `.json` and change `contentLength` to a wrong value, then reopen. Log should print:
```
[proxy] session=<id> cache invalidated: cachedLength=X remoteLength=Y
```

And the `.bin` should be recreated from scratch.
