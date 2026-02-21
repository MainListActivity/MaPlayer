# Proxy Streaming Refactor Design

**Date:** 2026-02-21
**Status:** Approved

## Problem

The current pseudo-streaming proxy has three concrete bugs:

1. **File corruption on concurrent writes** — `_downloadChunk` opens the cache file with `FileMode.write`, which truncates the file on every open. Concurrent chunk downloads overwrite each other's data.

2. **False concurrency in `_scheduleChunk`** — The method creates a `Completer`, starts an `unawaited` task, then immediately `await`s the completer. Every caller blocks until that chunk fully downloads, so prefetch and required chunks are serialized — there is no actual parallel downloading.

3. **Fragile retry hack in `_serveParallel`** — Reading from the cache file falls back to a 40 ms `Future.delayed` retry when data is empty, which is a race condition workaround rather than a correct solution.

Additionally, the HLS playlist/segment machinery (`handlePlaylistRequest`, `handleSegmentRequest`, `_probeMp4InitLength`, `/hls/` routes) adds complexity with no clear benefit — media_kit can play a direct HTTP byte-range stream without an HLS wrapper.

## Design

### 1. Remove HLS machinery

Delete all HLS-related code:
- `_ProxySession.handlePlaylistRequest`, `handleSegmentRequest`
- `_ProxySession._hlsSegmentBytes`, `_probeMp4InitLength`, `_mp4InitLength`, `_findMoovEnd`, `_readU32`, `_readU64`
- `_ProxySession.proxyUrl` field (unused after removal)
- `LocalStreamProxyServer.urlForPlaylist`, `urlForSegment`, `/hls/` routing
- `ProxyController._handlePlaylistRequest`, `_handleSegmentRequest`
- `onPlaylistRequest`, `onSegmentRequest` callbacks in `LocalStreamProxyServer`
- `ProxyController.createSession` no longer probes mp4 init; sets `playbackUrl = streamUrl`

`ResolvedPlaybackEndpoint.playbackUrl` becomes the `/stream/$sessionId` URL directly.

### 2. Fix cache file write mode

Change `FileMode.write` → `FileMode.writeOnly` in `_downloadChunk`:

```dart
final raf = await _cacheFile.open(mode: FileMode.writeOnly);
```

`FileMode.writeOnly` opens for random-access writing without truncating, allowing multiple concurrent chunks to write to different file positions safely.

### 3. Split `_scheduleChunk` into prefetch vs wait

Replace `_scheduleChunk` with two methods:

- **`_startPrefetch(int chunkIndex)`** — Ensures a download task is running for this chunk but does **not** await it. Idempotent: does nothing if the chunk is already downloaded or already in-flight.

- **`_waitForChunk(int chunkIndex) → Future<bool>`** — Starts a download if not already running, then awaits the in-flight future. Returns `true` if the chunk is ready in cache.

Call sites:
- `_ensureRangeAvailable`: required chunks use `await _waitForChunk(i)`, prefetch window uses `_startPrefetch(i)` (no await).
- `_serveParallel`: uses `await _waitForChunk(offset ~/ chunkSize)` in the serve loop.

### 4. Remove 40 ms retry hack

With `_waitForChunk` guaranteeing the chunk is fully written before returning, `_serveParallel` reads from cache without any retry. If `_waitForChunk` returns `false` (download failed), the session degrades to single mode and falls through to `_serveSingle`.

### 5. Cache & LRU (unchanged behavior, preserved)

- `closeSession` stops in-flight downloads (cancels remaining `_inFlight` futures), updates meta file (`lastAccessAt`, `downloadedChunkCount`), and **keeps** the cache `.bin` and `.json` files on disk.
- `_evictOldCaches` runs at session creation time, evicts oldest-accessed `.bin` files by `stat.modified` time until total size is under `_maxCacheBytes` (2 GB). This is the existing LRU behavior and is preserved as-is.
- Cache files from previous sessions are not reloaded (chunk bitmap not restored on reopen); re-downloading occurs for files that weren't fully cached.

## Files Changed

- `lib/features/player/proxy/proxy_controller.dart` — primary target
- `lib/features/player/proxy/proxy_models.dart` — remove `ProxyMode.parallel`/`single` if no longer needed (keep if stats UI uses it)
- `lib/features/playback/playback_models.dart` — no changes needed
