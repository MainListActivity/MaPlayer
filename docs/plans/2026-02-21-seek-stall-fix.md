# Seek Stall Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复用户拖动进度条后长时间转圈的问题：seek 时立即中止旧位置的预取任务（释放信号量），并通过直接桥接上游流立即响应新位置的请求。

**Architecture:** 在 `_ProxySession` 中新增两个机制：(1) seek 检测 + abort 标记集合，使旧 in-flight 任务在信号量获取后/下载完成后快速退出；(2) `_serveBridge` 方法，seek 时直接将上游 HTTP 响应流式转发给 media_kit，后台预取继续并行缓存。

**Tech Stack:** Flutter/Dart, `dart:io` (HttpClient, HttpRequest, RandomAccessFile)

---

### Task 1: 新增 `_abortedChunks` 字段和 `_abortOutOfWindowChunks` 方法

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

找到 `_ProxySession` 字段声明区（约第 418–458 行），在 `_playbackOffset` 字段之后新增字段和常量。

**Step 1: 新增 `_abortedChunks` 字段和 seek 阈值常量**

找到（约第 447 行）：
```dart
  int _playbackOffset = 0;
```

在其**后面**插入：
```dart
  static const int _seekThresholdBytes = 4 * 1024 * 1024; // 4 MB
  final Set<int> _abortedChunks = <int>{};
```

**Step 2: 新增 `_abortOutOfWindowChunks` 方法**

找到 `_startPrefetch` 方法（约第 1020 行），在其**前面**插入以下方法：

```dart
  /// Marks all in-flight chunks outside the new prefetch window as aborted.
  /// Aborted tasks check [_abortedChunks] at key points and exit early,
  /// releasing their semaphore slot immediately.
  void _abortOutOfWindowChunks(int newStart) {
    final length = _contentLength;
    if (length == null || length <= 0) return;
    final windowStartChunk = max(0, newStart - behindWindowBytes) ~/ chunkSize;
    final windowEndChunk =
        min(length - 1, newStart + aheadWindowBytes) ~/ chunkSize;
    for (final idx in _inFlight.keys.toList()) {
      if (idx < windowStartChunk || idx > windowEndChunk) {
        _abortedChunks.add(idx);
      }
    }
  }
```

**Step 3: 分析验证**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

期望：无 error。

**Step 4: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat: add _abortedChunks set and _abortOutOfWindowChunks method"
```

---

### Task 2: 在 `_startPrefetch` 中插入 abort 检查点

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`（`_startPrefetch` 方法，约第 1020–1067 行）

当前 `_startPrefetch` 的 unawaited 任务体：

```dart
    unawaited(() async {
      await _semaphore.acquire();
      _activeWorkers += 1;
      try {
        if (_downloadedChunks.contains(chunkIndex)) {
          completer.complete(true);
          return;
        }
        if (_mode != ProxyMode.parallel) {
          completer.complete(false);
          return;
        }
        final data = await _downloadChunk(chunkIndex);
        if (data == null || _mode != ProxyMode.parallel) {
          completer.complete(false);
          return;
        }
        // Store in memory buffer so serve can read immediately.
        _chunkBuffer[chunkIndex] = data;
        _downloadedChunks.add(chunkIndex);
        // Signal serve that the chunk is ready before disk write completes.
        completer.complete(true);
        // Persist to disk asynchronously — does not block serve.
        final persistFuture = _persistChunk(chunkIndex, data);
        _pendingPersists.add(persistFuture);
        unawaited(persistFuture.whenComplete(() => _pendingPersists.remove(persistFuture)));
      } catch (e, st) {
        if (!_isDisposing && !_isDisposed && !_isClientClosedError(e)) {
          logger('chunk task failed: chunk=$chunkIndex, e=$e\n$st');
        }
        completer.completeError(e, st);
      } finally {
        _activeWorkers = max(0, _activeWorkers - 1);
        _inFlight.remove(chunkIndex);
        _semaphore.release();
      }
    }());
```

**Step 1: 替换 `_startPrefetch` 的 unawaited 任务体（新增两个 abort 检查点）**

用以下代码替换上面整个 `unawaited(() async { ... }());` 块：

```dart
    unawaited(() async {
      await _semaphore.acquire();
      _activeWorkers += 1;
      try {
        // Checkpoint 1: abort before doing any work (seek cleared this slot).
        if (_abortedChunks.contains(chunkIndex)) {
          completer.complete(false);
          return;
        }
        if (_downloadedChunks.contains(chunkIndex)) {
          completer.complete(true);
          return;
        }
        if (_mode != ProxyMode.parallel) {
          completer.complete(false);
          return;
        }
        final data = await _downloadChunk(chunkIndex);
        // Checkpoint 2: abort after download completes (seek happened mid-download).
        if (_abortedChunks.contains(chunkIndex)) {
          completer.complete(false);
          return;
        }
        if (data == null || _mode != ProxyMode.parallel) {
          completer.complete(false);
          return;
        }
        // Store in memory buffer so serve can read immediately.
        _chunkBuffer[chunkIndex] = data;
        _downloadedChunks.add(chunkIndex);
        // Signal serve that the chunk is ready before disk write completes.
        completer.complete(true);
        // Persist to disk asynchronously — does not block serve.
        final persistFuture = _persistChunk(chunkIndex, data);
        _pendingPersists.add(persistFuture);
        unawaited(persistFuture.whenComplete(() => _pendingPersists.remove(persistFuture)));
      } catch (e, st) {
        if (!_isDisposing && !_isDisposed && !_isClientClosedError(e)) {
          logger('chunk task failed: chunk=$chunkIndex, e=$e\n$st');
        }
        completer.completeError(e, st);
      } finally {
        _activeWorkers = max(0, _activeWorkers - 1);
        _inFlight.remove(chunkIndex);
        _abortedChunks.remove(chunkIndex); // cleanup
        _semaphore.release();
      }
    }());
```

**关键变化说明：**
- Checkpoint 1（acquire 后）：如果 chunk 在 `_abortedChunks` 中，立即 `complete(false)` 并 return，`finally` 释放信号量
- Checkpoint 2（download 后）：即使下载完成，如果 seek 已中止该 chunk，丢弃数据
- `finally` 中清理 `_abortedChunks.remove(chunkIndex)`

**Step 2: 在 `_persistChunk` 中添加 abort 守卫**

找到 `_persistChunk` 方法（约第 972 行），在 `await _writeLock.acquire();` 之前插入：

```dart
    // Skip write if this chunk was aborted during a seek.
    if (_abortedChunks.contains(chunkIndex)) {
      _chunkBuffer.remove(chunkIndex);
      return;
    }
```

完整的 `_persistChunk` 改后如下：
```dart
  Future<void> _persistChunk(int chunkIndex, List<List<int>> data) async {
    final length = _contentLength;
    if (length == null) return;
    final start = chunkIndex * chunkSize;
    // Skip write if this chunk was aborted during a seek.
    if (_abortedChunks.contains(chunkIndex)) {
      _chunkBuffer.remove(chunkIndex);
      return;
    }
    await _writeLock.acquire();
    try {
      final raf = _writeRaf;
      if (raf == null) return; // Session disposed; cache file already closed.
      await raf.setPosition(start);
      for (final chunk in data) {
        await raf.writeFrom(chunk);
      }
    } finally {
      _writeLock.release();
      _chunkBuffer.remove(chunkIndex);
      _scheduleMeta();
    }
  }
```

**Step 3: 分析验证**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

期望：无 error。

**Step 4: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat: add abort checkpoints in _startPrefetch and _persistChunk"
```

---

### Task 3: 新增 `_serveBridge` 方法

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

在 `_serveSingle` 方法（约第 666 行）之后，`_serveHead` 方法之前，插入新方法 `_serveBridge`。

**Step 1: 插入 `_serveBridge` 方法**

找到（约第 693 行）：
```dart
  Future<void> _serveHead(HttpRequest request, _RequestRange? range) async {
```

在该行**之前**插入：

```dart
  /// Streams the requested range directly from the upstream source to the
  /// client, bypassing the chunk cache. Used immediately after a seek so
  /// media_kit gets data without waiting for background downloads to complete.
  /// Does not write to the cache to avoid races with parallel prefetch tasks.
  Future<void> _serveBridge(HttpRequest request, _RequestRange requested) async {
    if (_isDisposing || _isDisposed) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }
    final length = _contentLength!;
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      _contentType ?? 'video/mp4',
    );
    request.response.headers.set(
      HttpHeaders.contentLengthHeader,
      '${requested.end! - requested.start + 1}',
    );
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes ${requested.start}-${requested.end!}/$length',
    );

    try {
      final uri = Uri.parse(sourceUrl);
      final upstreamRequest = await _client.getUrl(uri);
      _applyHeaders(upstreamRequest.headers, headers);
      upstreamRequest.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=${requested.start}-${requested.end!}',
      );
      _logUpstreamRequestHeaders('serveBridge', upstreamRequest.headers);

      final upstreamResponse = await upstreamRequest.close();
      await for (final chunk in upstreamResponse) {
        _recordDownloadedBytes(chunk.length);
        _recordServedBytes(chunk.length);
        request.response.add(chunk);
      }
    } catch (e) {
      if (!_isDisposing && !_isDisposed && !_isClientClosedError(e)) {
        logger('session=$sessionId bridge failed: $e');
      }
    }
    await request.response.close();
  }

```

**Step 2: 分析验证**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

期望：无 error。

**Step 3: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat: add _serveBridge for seek-time direct upstream streaming"
```

---

### Task 4: 修改 `_serveParallel` — 在 seek 时走 bridge 分支

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`（`_serveParallel` 方法，约第 739–869 行）

**Step 1: 在 `_normalizeRequestedRange` 之后、`_playbackOffset` 赋值之前，插入 seek 检测和 bridge 分支**

找到（约第 762 行）：
```dart
    _playbackOffset = requested.start;
    final startupEnd = min(
      requested.end!,
      requested.start + max(chunkSize, 512 * 1024).toInt() - 1,
    );
    await _ensureRangeAvailable(requested.start, startupEnd);
    if (_mode == ProxyMode.single) {
      await _serveSingle(request, requested);
      return;
    }

    final firstChunkReady = await _ensureChunkReady(
      requested.start ~/ chunkSize,
    );
    if (!firstChunkReady || _mode == ProxyMode.single) {
      await _serveSingle(request, requested);
      return;
    }
```

用以下代码替换上面这段：

```dart
    // Detect seek: large jump from current playback position.
    final isSeek =
        (requested.start - _playbackOffset).abs() > _seekThresholdBytes &&
        _playbackOffset > 0;
    if (isSeek) {
      logger(
        'session=$sessionId seek detected: '
        'from=$_playbackOffset to=${requested.start}, '
        'aborting out-of-window prefetch tasks',
      );
      _abortOutOfWindowChunks(requested.start);
    }
    _playbackOffset = requested.start;

    // Start background prefetch for the new window (non-blocking).
    final startupEnd = min(
      requested.end!,
      requested.start + max(chunkSize, 512 * 1024).toInt() - 1,
    );
    _ensureRangeAvailableBackground(requested.start, startupEnd);

    if (isSeek) {
      // Bridge: stream directly from upstream so media_kit gets data
      // immediately without waiting for background chunks to arrive.
      await _serveBridge(request, requested);
      return;
    }

    await _ensureRangeAvailable(requested.start, startupEnd);
    if (_mode == ProxyMode.single) {
      await _serveSingle(request, requested);
      return;
    }

    final firstChunkReady = await _ensureChunkReady(
      requested.start ~/ chunkSize,
    );
    if (!firstChunkReady || _mode == ProxyMode.single) {
      await _serveSingle(request, requested);
      return;
    }
```

**Step 2: 新增 `_ensureRangeAvailableBackground` 方法**

`_ensureRangeAvailable` 是 async 且会 await 必需 chunks。seek 分支中我们只需要**触发预取窗口**，不等待。新增一个非阻塞版本。

找到 `_ensureRangeAvailable` 方法（约第 871 行），在其**后面**插入：

```dart
  /// Kicks off background prefetch for the window around [start] without
  /// waiting for any chunk to complete. Used on seek to warm the cache while
  /// _serveBridge handles the immediate response.
  void _ensureRangeAvailableBackground(int start, int end) {
    final length = _contentLength;
    if (length == null || length <= 0) return;
    final windowStart = max(0, start - behindWindowBytes);
    final windowEnd = min(length - 1, start + aheadWindowBytes);
    final prefetchStartChunk = windowStart ~/ chunkSize;
    final prefetchEndChunk = windowEnd ~/ chunkSize;
    for (var i = prefetchStartChunk; i <= prefetchEndChunk; i++) {
      _startPrefetch(i);
    }
  }
```

**Step 3: 分析验证**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

期望：无 error。

**Step 4: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "feat: detect seek in _serveParallel, abort old prefetch, bridge upstream on seek"
```

---

### Task 5: 全量分析 + 日志验证

**Files:** 无新改动

**Step 1: 全项目分析**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter analyze
```

期望：无 error（info/warning 可接受）。

**Step 2: 确认 seek 检测逻辑不会误触发**

检查 `_playbackOffset` 的初始值为 `0`，以及 `isSeek` 判断里的 `&& _playbackOffset > 0` 守卫：
- 第一次请求（`_playbackOffset == 0`, `requested.start == 0`）：diff = 0，不触发 seek，走正常并行缓存路径。
- 正常顺序播放（每次请求 start 接近上次 end）：diff 远小于 4MB，不触发 seek。
- 拖动进度条（新 start 与旧 offset 相差几十 MB）：diff >> 4MB，触发 seek → bridge。

**Step 3: 确认 `_abortedChunks` cleanup 正确**

通过 grep 确认 `_abortedChunks.remove` 只在 `_startPrefetch` 的 `finally` 块中，以及 `_persistChunk` 的 abort 守卫中：

```bash
grep -n '_abortedChunks' lib/features/player/proxy/proxy_controller.dart
```

期望输出包含以下几行（行号可能有出入）：
```
  final Set<int> _abortedChunks = <int>{};      ← 字段声明
  _abortedChunks.add(idx);                       ← _abortOutOfWindowChunks
  if (_abortedChunks.contains(chunkIndex)) {     ← checkpoint 1 in _startPrefetch
  if (_abortedChunks.contains(chunkIndex)) {     ← checkpoint 2 in _startPrefetch
  _abortedChunks.remove(chunkIndex);             ← finally in _startPrefetch
  if (_abortedChunks.contains(chunkIndex)) {     ← _persistChunk guard
```

**Step 4: Final commit（如有遗漏清理）**

```bash
git status
# 如有未提交改动:
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "chore: final seek-stall fix cleanup"
```
