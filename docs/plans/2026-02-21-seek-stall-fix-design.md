# Seek Stall Fix Design

**Date:** 2026-02-21
**Status:** Approved

## Problem

After the user drags the progress bar, playback enters a loading spinner for 10–30 seconds before recovering. Root cause: seeking to a new position while all 8 semaphore slots are occupied by in-flight chunk downloads for the old playback position. The newly required chunk must queue behind them.

Additionally, media_kit sends open-ended range requests (`bytes=X-`), so even the initial seek response is blocked until the required chunk finishes downloading.

## Design

Two complementary mechanisms are added to `_ProxySession`:

### 1. Seek Detection + Abort

**Seek detection threshold:** `_seekThresholdBytes = 4 MB`

At the start of `_serveParallel`, compute:
```dart
final isSeek = (requested.start - _playbackOffset).abs() > _seekThresholdBytes;
```

When a seek is detected, call `_abortOutOfWindowChunks(newStart)`:
- Compute the new prefetch window: `[newStart - behindWindowBytes, newStart + aheadWindowBytes]`
- For every in-flight chunk index outside this window, add it to `_abortedChunks` (a `Set<int>`)

**Three abort checkpoints in `_startPrefetch` tasks:**

1. **After `_semaphore.acquire()`** — if chunk is in `_abortedChunks`, immediately `complete(false)` and release semaphore (no download)
2. **After `_downloadChunk` returns** — if chunk is in `_abortedChunks`, discard downloaded data, `complete(false)`, do not write to cache
3. **In `_persistChunk`** — skip persistence if chunk is in `_abortedChunks`

This ensures aborted tasks exit quickly and release semaphore slots for the new position's chunks.

**Cleanup:** `_abortedChunks` entries are removed when the task fully exits (in `finally`). The set is cleared when a new session starts (inherently via new `_ProxySession` instance).

### 2. Streaming Bridge on Seek

When `isSeek == true`, instead of waiting for cache chunks, `_serveParallel` immediately calls `_serveBridge(request, requested)`.

**`_serveBridge` behavior:**
- Sets response headers: `206 Partial Content`, `Content-Range: bytes start-end/total`, `Content-Length`
- Opens a direct upstream HTTP request with `Range: bytes=start-end`
- Streams chunks directly: `await for (chunk in upstreamResponse) { request.response.add(chunk); }`
- Records download bytes and serve bytes
- Does **not** write to cache (avoids conflict with parallel prefetch tasks)
- Closes response when upstream response completes

Background prefetch (`_startPrefetch`) is still triggered before the bridge call, so subsequent playback requests (non-seek) will be served from cache.

### 3. Updated `_serveParallel` Flow

```
Receive request
  ↓
Detect seek (|requested.start - _playbackOffset| > 4 MB)
  ↓ yes                          ↓ no
abortOutOfWindowChunks     (existing flow)
  ↓
_ensureRangeAvailable       ensureRangeAvailable
(starts background prefetch) (waits for required chunks)
  ↓
_serveBridge                ensureChunkReady → serve from cache
(stream upstream directly)
```

## Files Changed

- `lib/features/player/proxy/proxy_controller.dart`
  - `_ProxySession`: add `_abortedChunks`, `_seekThresholdBytes`, `_abortOutOfWindowChunks`, `_serveBridge`
  - `_serveParallel`: add seek detection branch
  - `_startPrefetch`: add abort checkpoints
  - `_persistChunk`: add abort guard

## Non-Goals

- Does not cancel the HTTP connection of in-flight downloads (Dart's `HttpClient` does not support mid-request cancellation cleanly; instead we abort at the semaphore and post-download checkpoints)
- Does not write bridge-streamed data to cache (avoids double-write races with prefetch tasks)
