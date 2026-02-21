# Chunk-Level LRU & Playback Progress Persistence

Date: 2026-02-21

## Overview

Two independent features for `ProxyController` / `_ProxySession`:

1. **Chunk-level LRU** — evict least-recently-used chunks from `_downloadedChunks` when a session exceeds its chunk budget, so the warm-cache metadata stays accurate after eviction.
2. **Playback progress persistence** — save `_playbackOffset` to the session's `.json` sidecar on close/switch, restore it on next open, and expose it so `PlayerPage` can seek to the last position.

---

## Feature 1: Chunk-Level LRU

### Problem

`_evictOldCaches` operates at the file (session) level — it deletes entire `.bin` + `.json` pairs when total disk usage exceeds `_maxCacheBytes`. Within a single session there is no upper bound on how many chunks accumulate. More importantly, when a file IS evicted at the session level, `_downloadedChunks` lives only in memory and is never updated; the on-disk `.json` that survives an eviction may reference chunks whose data is gone.

### Design

#### New fields on `_ProxySession`

```dart
// LRU order: key = chunk index, value = last-access ms-since-epoch.
// LinkedHashMap preserves insertion order → head = oldest entry.
final LinkedHashMap<int, int> _chunkAccessOrder = LinkedHashMap();

// Maximum chunks this session may hold in _downloadedChunks at one time.
// Computed once in initialize() as (maxCacheBytes / chunkSize).clamp(16, 1024).
late final int _maxChunks;
```

`maxCacheBytes` (existing constant `2 GB`) is threaded from `ProxyController` into `_ProxySession` as a new constructor parameter.

#### Touch on access

Any path that marks a chunk as available or reads from it calls:

```dart
void _touchChunk(int chunkIndex) {
  _chunkAccessOrder.remove(chunkIndex); // remove from current position
  _chunkAccessOrder[chunkIndex] = DateTime.now().millisecondsSinceEpoch; // append to tail
}
```

Call sites:
- `_startPrefetch` — after `_downloadedChunks.add(chunkIndex)`
- `_serveParallel` — each time `chunkIndex` is selected for reading

#### Eviction

Called immediately after `_touchChunk` inside `_startPrefetch`:

```dart
void _evictChunksIfNeeded() {
  while (_downloadedChunks.length > _maxChunks) {
    final oldest = _chunkAccessOrder.keys.first;
    _downloadedChunks.remove(oldest);
    _chunkBuffer.remove(oldest);
    _chunkAccessOrder.remove(oldest);
    // Disk data at that offset is left intact; it will be overwritten
    // the next time the chunk is re-downloaded.
  }
}
```

**No physical disk erasure.** Evicted chunks are simply forgotten from the in-memory tracking set. The `.bin` file retains stale bytes at those offsets; they are overwritten if the chunk is re-downloaded. This avoids the need for platform-specific sparse-file (punch-hole) APIs.

#### Metadata accuracy

`_writeMeta` serialises `_downloadedChunks` as-is. After eviction, evicted chunk indices are absent from the list, so a subsequent warm-cache restore correctly excludes them and schedules re-downloads.

#### Session-level eviction interaction

When `_evictOldCaches` deletes a `.bin` + `.json` pair the session is either already disposed (no active `_ProxySession`) or the eviction runs before the session is created. In both cases `_downloadedChunks` is irrelevant, so no extra synchronisation is needed.

---

## Feature 2: Playback Progress Persistence

### Problem

There is no mechanism to resume playback from the last-watched byte offset when reopening a file. `_playbackOffset` is updated continuously during `_serveParallel` but is never saved.

### Design

#### Granularity

Progress is keyed by `sessionId` (derived from `fileKey` or URL), which already encodes the cloud-file identity and headers. Different quality variants of the same episode share a URL and thus a `sessionId`, consistent with the user's expectation.

#### Storage format — additions to `.json`

```json
{
  "sessionId": "...",
  "contentLength": 12345678,
  "downloadedChunks": [0, 1, 2],
  "lastPlaybackPosition": 83886080
}
```

`lastPlaybackPosition` is a byte offset (same unit as `_playbackOffset`).

#### Write path

In `_ProxySession.dispose()`, `_writeMeta()` is already called as the final step. Add `lastPlaybackPosition` to the payload:

```dart
'lastPlaybackPosition': _playbackOffset,
```

No new write path is needed — the existing dispose-time flush covers close and media-switch (the previous session is disposed when a new one is created).

#### Read path

In `_ProxySession.initialize()`, after parsing the cached `.json`:

```dart
int? restoredPlaybackPosition;
// ... existing chunk-restore logic ...
restoredPlaybackPosition = map['lastPlaybackPosition'] as int?;
```

Store as:
```dart
int? _restoredPlaybackPosition; // null if no prior session
```

#### API surface on `ProxyController`

```dart
/// Returns the last saved playback byte offset for [sessionId], or null.
int? getRestoredPosition(String sessionId) =>
    _sessions[sessionId]?._restoredPlaybackPosition;
```

Because `_ProxySession` is private, `_restoredPlaybackPosition` is exposed via a getter on `_ProxySession` called by `ProxyController`.

#### Seek in `PlayerPage`

After `_playerController.open(endpoint.playbackUrl)` succeeds, and only when using the proxy:

```dart
final sessionId = endpoint.proxySession?.sessionId;
if (sessionId != null) {
  final byteOffset = ProxyController.instance.getRestoredPosition(sessionId);
  if (byteOffset != null && byteOffset > 0) {
    // Wait for duration to become known (media_kit emits it shortly after open)
    final contentLength = /* query from ProxyController or session descriptor */;
    final duration = await _waitForDuration();
    if (contentLength != null && contentLength > 0 && duration > Duration.zero) {
      final seekTo = duration * byteOffset / contentLength;
      await _playerController.player.seek(seekTo);
    }
  }
}
```

`_waitForDuration` listens to `player.stream.duration` and completes on the first non-zero value with a short timeout (e.g. 5 s).

`contentLength` is added to `ProxySessionDescriptor` so `PlayerPage` can read it without reaching into internals.

---

## Out of Scope

- Physical sparse-file punch-hole (punch-hole LRU) — deferred due to FFI complexity
- Periodic progress autosave — close/switch-time persistence is sufficient for now
- Per-quality-variant progress (sub-sessionId granularity) — not needed

---

## Affected Files

| File | Change |
|------|--------|
| `proxy_controller.dart` | Add `_maxChunks`, `_chunkAccessOrder`, `_touchChunk`, `_evictChunksIfNeeded`; add `lastPlaybackPosition` to `_writeMeta`; read it in `initialize`; expose `getRestoredPosition` on `ProxyController`; thread `maxCacheBytes` into `_ProxySession` |
| `proxy_models.dart` | Add `contentLength` field to `ProxySessionDescriptor` |
| `player_page.dart` | After `open()`, query restored position and seek |
