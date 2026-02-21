# Warm-Cache Design

Date: 2026-02-21

## Problem

`_ProxySession` tracks downloaded chunks only in memory (`_downloadedChunks: Set<int>`).
On session restart (same video reopened), `initialize()` opens `.bin` with `FileMode.write`
(truncates the file) and starts with an empty set — all previously downloaded chunks are lost.

## Goal

Reuse disk-cached chunks across sessions for the same file, eliminating redundant network
downloads when a video is reopened.

## Session Identity

`sessionId` is the MD5 of `sourceUrl + fileKey` (or `sourceUrl + headers`). When `fileKey`
is derived from the cloud-drive `fid`, it is stable across URL refreshes. This guarantees
that the same file always maps to the same `.bin`/`.json` pair.

## Chosen Approach: Persist chunk index list in `.json`

Extend the existing `.json` sidecar to store which chunk indices have been fully downloaded.
On session init, read this list back and restore `_downloadedChunks`. Validate against the
remote `contentLength`; invalidate the whole cache on mismatch.

## `.json` Format

```json
{
  "sessionId": "...",
  "sourceUrl": "...",
  "mode": "parallel",
  "createdAt": "...",
  "lastAccessAt": "...",
  "contentLength": 1073741824,
  "downloadedChunks": [0, 1, 2, 5, 6, 7],
  "downloadedChunkCount": 6,
  "degradeReason": null
}
```

`downloadedChunks` replaces the previous `downloadedChunkCount`-only field (count is kept
for quick human inspection).

## `initialize()` Changes

```
1. Resolve .bin / .json paths (unchanged).
2. If .json exists → parse cachedContentLength and cachedChunks.
3. Probe remote for contentLength (existing _probeRangeSupport).
4a. If cachedContentLength != remoteContentLength (or probe failed):
      - Delete .bin and .json.
      - Open fresh .bin with FileMode.write (truncate).
      - _downloadedChunks stays empty.
4b. If lengths match:
      - Open .bin with FileMode.writeOnlyAppend (no truncation).
      - Populate _downloadedChunks from cachedChunks.
5. Continue as before.
```

## Meta Write Strategy: Debounced 5 s

After each `_persistChunk()` call, schedule a debounced `_writeMeta()` with a 5-second
delay. If another chunk is persisted within the window, the timer resets. This amortises
JSON IO across concurrent 8-worker downloads while still capturing progress frequently
enough to survive most crashes.

`dispose()` cancels the debounce timer and calls `_writeMeta()` synchronously before
closing the RAF.

## `_writeMeta()` Changes

```dart
'downloadedChunks': (_downloadedChunks.toList()..sort()),
'downloadedChunkCount': _downloadedChunks.length,
```

## Invalidation on Content-Length Mismatch

When remote `contentLength` differs from cached value:
1. Close and delete `.bin`.
2. Delete `.json`.
3. Recreate `.bin` with `FileMode.write`.
4. Reset `_downloadedChunks` to empty.
5. Proceed with fresh download.

## Non-Goals

- Partial-chunk recovery (incomplete chunks are not tracked; only fully persisted chunks
  are recorded in `downloadedChunks`).
- Cross-device or shared caches.
- Manual cache invalidation UI (out of scope for this change).
