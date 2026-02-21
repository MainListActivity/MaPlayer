# Proxy Streaming Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 移除 HLS 分片逻辑，修复并发写入 bug 和伪并发 bug，让代理服务器以标准 HTTP Range 方式直接响应 media_kit。

**Architecture:** 本地 HTTP 代理服务器接受 `/stream/$sessionId` 的 range 请求，后台并发下载网盘分片到本地缓存文件，serve 端从缓存文件响应。拆分 `_scheduleChunk` 为 `_startPrefetch`（不阻塞）和 `_waitForChunk`（阻塞等待），消除伪并发。

**Tech Stack:** Flutter/Dart, `dart:io` (HttpServer, RandomAccessFile)

---

### Task 1: 移除 LocalStreamProxyServer 中的 HLS 路由和回调

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

**Step 1: 删除 `LocalStreamProxyServer` 的 HLS 相关字段和方法**

在 `LocalStreamProxyServer` 类中：
- 删除构造函数参数 `onPlaylistRequest` 和 `onSegmentRequest`
- 删除字段 `onPlaylistRequest` 和 `onSegmentRequest`
- 删除方法 `urlForPlaylist` 和 `urlForSegment`
- 在 `_handle` 方法中删除以下两个路由块（保留 `/stream/` 路由和末尾的 404）：

```dart
// 删除这整块:
if (path.startsWith('/hls/') && path.endsWith('/index.m3u8')) {
  ...
}
// 删除这整块:
final segMatch = RegExp(r'^/hls/([^/]+)/seg/(\d+)\.m4s$').firstMatch(path);
if (segMatch != null) {
  ...
}
```

**Step 2: 更新 `LocalStreamProxyServer` 构造函数调用**

在 `ProxyController.createSession` 中，`_server ??= LocalStreamProxyServer(...)` 那里删除 `onPlaylistRequest` 和 `onSegmentRequest` 两个参数。

**Step 3: 删除 `ProxyController` 中的 HLS 处理方法**

删除：
```dart
Future<void> _handlePlaylistRequest(...) async { ... }
Future<void> _handleSegmentRequest(...) async { ... }
```

**Step 4: 更新 `createSession` 返回值**

`createSession` 中：
- 删除 `if (_isM3u8Like(media.url))` 提前返回块（M3U8 直接透传，不走代理，可保留）
- 将 `playbackUrl: _server!.urlForPlaylist(sessionId)` 改为 `playbackUrl: _server!.urlForSession(sessionId)`
- 同样更新 existing session 返回处的 `playbackUrl`
- 删除构造 `_ProxySession` 时的 `proxyUrl: _server!.urlForPlaylist(sessionId)` 参数（和字段）

**Step 5: 手动验证编译**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

期望：无 error（可有 warning/info）。

**Step 6: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "refactor: remove HLS playlist/segment machinery from proxy"
```

---

### Task 2: 移除 `_ProxySession` 中的 HLS 和 mp4-init 代码

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

**Step 1: 删除 `_ProxySession` 中的 HLS 常量和字段**

删除：
```dart
static const int _hlsSegmentBytes = 4 * 1024 * 1024;
```

删除字段：
```dart
late final String proxyUrl;  // 如果还剩
int? _mp4InitLength;
```

**Step 2: 删除 HLS 和 mp4-init 相关方法**

删除以下方法：
- `handlePlaylistRequest`
- `handleSegmentRequest`
- `_probeMp4InitLength`
- `_findMoovEnd`
- `_readU32`
- `_readU64`

**Step 3: 清理 `initialize()` 中的 mp4-init 调用**

在 `initialize()` 中删除：
```dart
_mp4InitLength = await _probeMp4InitLength();
```

**Step 4: 清理 `descriptor` getter**

`ProxySessionDescriptor` 如果有 `proxyUrl` 字段，从 `descriptor` getter 和 `ProxySessionDescriptor` 构造函数调用中删除（如果 `proxy_models.dart` 中 `ProxySessionDescriptor` 有该字段，也一并删除）。

**Step 5: 编译验证**

```bash
flutter analyze lib/features/player/proxy/
```

期望：无 error。

**Step 6: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart lib/features/player/proxy/proxy_models.dart
git commit -m "refactor: remove mp4-init probing and HLS session fields"
```

---

### Task 3: 修复 `_downloadChunk` 的文件写入模式

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`（`_downloadChunk` 方法，约 818 行）

**Step 1: 找到并修改 FileMode**

在 `_downloadChunk` 中，找到：
```dart
final raf = await _cacheFile.open(mode: FileMode.write);
```

改为：
```dart
final raf = await _cacheFile.open(mode: FileMode.writeOnly);
```

**说明：** Dart 的 `FileMode.write` 会截断文件（等同于 O_WRONLY|O_TRUNC），并发时不同 chunk 会互相清除对方已写的数据。`FileMode.writeOnly` 不截断，允许 `setPosition` 后在任意位置写入，这正是并发分片写入所需的行为。

**Step 2: 确认缓存文件初始化大小**

目前 `initialize()` 只调用 `_cacheFile.create()`，不预分配文件大小。`FileMode.writeOnly` 允许在任意 offset 写，但如果文件太小会自动扩展——Dart `RandomAccessFile` 的 `writeFrom` 会在当前 position 写，超出 EOF 部分自动延伸，这是正确的。无需额外改动。

**Step 3: 编译和分析**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

**Step 4: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "fix: use FileMode.writeOnly to prevent cache file truncation on concurrent chunk writes"
```

---

### Task 4: 拆分 `_scheduleChunk` 为 `_startPrefetch` 和 `_waitForChunk`

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

这是最核心的修复。当前 `_scheduleChunk` 的问题：它同时负责"启动下载"和"等待完成"，导致所有调用方被串行阻塞。

**Step 1: 修改 `_inFlight` 的类型**

将字段：
```dart
final Map<int, Future<void>> _inFlight = <int, Future<void>>{};
```
改为存储 `Completer`，以便区分"启动"和"等待"：
```dart
final Map<int, Completer<bool>> _inFlight = <int, Completer<bool>>{};
```
（`bool` 表示 chunk 是否成功写入，`true` = 成功）

**Step 2: 用新方法替换 `_scheduleChunk`**

**删除** 整个 `_scheduleChunk` 方法，**新增** 以下两个方法：

```dart
/// 启动 chunk 下载，不等待完成。幂等：已下载或已在飞行中时什么都不做。
void _startPrefetch(int chunkIndex) {
  if (_mode == ProxyMode.single) return;
  final length = _contentLength;
  if (length == null || length <= 0) return;
  if (chunkIndex < 0 || chunkIndex * chunkSize >= length) return;
  if (_downloadedChunks.contains(chunkIndex)) return;
  if (_inFlight.containsKey(chunkIndex)) return;

  final completer = Completer<bool>();
  _inFlight[chunkIndex] = completer;

  unawaited(() async {
    await _semaphore.acquire();
    _activeWorkers += 1;
    try {
      bool ok = false;
      if (!_downloadedChunks.contains(chunkIndex) &&
          _mode == ProxyMode.parallel) {
        ok = await _downloadChunk(chunkIndex);
        if (ok && _mode == ProxyMode.parallel) {
          _downloadedChunks.add(chunkIndex);
        }
      } else if (_downloadedChunks.contains(chunkIndex)) {
        ok = true;
      }
      completer.complete(ok);
    } catch (e, st) {
      logger('chunk task failed: chunk=$chunkIndex, e=$e\n$st');
      completer.completeError(e, st);
    } finally {
      _activeWorkers = max(0, _activeWorkers - 1);
      _inFlight.remove(chunkIndex);
      _semaphore.release();
    }
  }());
}

/// 等待 chunk 可用（如果还未启动则先启动）。
/// 返回 true 表示 chunk 已在缓存中可读。
Future<bool> _waitForChunk(int chunkIndex) async {
  if (_mode == ProxyMode.single) return false;
  if (_downloadedChunks.contains(chunkIndex)) return true;

  final existing = _inFlight[chunkIndex];
  if (existing != null) {
    try {
      return await existing.future;
    } catch (_) {
      return false;
    }
  }

  // 还没启动，现在启动并等待
  _startPrefetch(chunkIndex);
  final started = _inFlight[chunkIndex];
  if (started == null) {
    // 可能在 _startPrefetch 内部检查后立即发现已存在
    return _downloadedChunks.contains(chunkIndex);
  }
  try {
    return await started.future;
  } catch (_) {
    return false;
  }
}
```

**Step 3: 更新 `_ensureRangeAvailable`**

将原来的：
```dart
final requiredFutures = <Future<void>>[];
for (var i = needStartChunk; i <= needEndChunk; i++) {
  requiredFutures.add(_scheduleChunk(i));
}
// ...
for (var i = prefetchStartChunk; i <= prefetchEndChunk; i++) {
  unawaited(_scheduleChunk(i));
}
// ...
for (final future in requiredFutures) {
  await future;
  if (_mode == ProxyMode.single) return;
}
```

改为：
```dart
// 预取窗口（不等待）
for (var i = prefetchStartChunk; i <= prefetchEndChunk; i++) {
  _startPrefetch(i);
}

// 等待必需的 chunks
for (var i = needStartChunk; i <= needEndChunk; i++) {
  final ok = await _waitForChunk(i);
  if (!ok || _mode == ProxyMode.single) return;
}
```

注意：必需 chunks 已被预取窗口覆盖（必需范围是预取窗口的子集），所以调用 `_waitForChunk` 时任务已在飞行中，直接 await 即可。

**Step 4: 更新 `_ensureChunkReady`**

将：
```dart
Future<bool> _ensureChunkReady(int chunkIndex) async {
  if (_mode == ProxyMode.single) return false;
  if (_downloadedChunks.contains(chunkIndex)) return true;
  await _scheduleChunk(chunkIndex);
  return _downloadedChunks.contains(chunkIndex);
}
```

改为直接用 `_waitForChunk`（或直接内联删除这个方法，在调用处直接用 `_waitForChunk`）：

```dart
Future<bool> _ensureChunkReady(int chunkIndex) => _waitForChunk(chunkIndex);
```

**Step 5: 更新 `_serveParallel` 的 serve 循环**

找到 `_serveParallel` 中 serve 循环：
```dart
while (offset <= end) {
  final chunkReady = await _ensureChunkReady(offset ~/ chunkSize);
  if (!chunkReady || _mode == ProxyMode.single) {
    throw StateError('chunk not ready at offset=$offset');
  }
  final remaining = end - offset + 1;
  final readLen = min(remaining, 64 * 1024);
  await raf.setPosition(offset);
  var data = await raf.read(readLen);
  if (data.isEmpty) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    data = await raf.read(readLen);
  }
  if (data.isEmpty) {
    throw StateError('cache data missing at $offset');
  }
  ...
}
```

改为（移除 40ms retry hack，chunk ready 后直接读取）：
```dart
while (offset <= end) {
  final chunkReady = await _ensureChunkReady(offset ~/ chunkSize);
  if (!chunkReady || _mode == ProxyMode.single) {
    // Degrade: chunk failed to download, fall through to single mode
    await raf.close();
    _degradeToSingle('chunk ${ offset ~/ chunkSize } not ready during serve');
    await _serveSingle(request, requested);
    return;
  }
  final remaining = end - offset + 1;
  final readLen = min(remaining, 64 * 1024);
  await raf.setPosition(offset);
  final data = await raf.read(readLen);
  if (data.isEmpty) {
    throw StateError('cache data missing at offset=$offset after chunk ready');
  }
  _recordServedBytes(data.length);
  request.response.add(data);
  offset += data.length;
}
```

注意：这里的 `raf.close()` 需要移出 try-finally，因为提前 return。更干净的做法是将整个 serve 循环用 try-finally 包裹，raf 在 finally 中关闭（原来就有 try-finally，保持结构即可）。

**Step 6: 更新 `dispose`**

原 `dispose` 等待所有 in-flight：
```dart
final inflight = _inFlight.values.toList(growable: false);
if (inflight.isNotEmpty) {
  await Future.wait(inflight.map((f) => f.catchError((_) {})));
}
```

由于 `_inFlight` 现在是 `Map<int, Completer<bool>>`，改为：
```dart
final inflight = _inFlight.values.toList(growable: false);
if (inflight.isNotEmpty) {
  await Future.wait(
    inflight.map((c) => c.future.then((_) {}, onError: (_) {})),
  );
}
```

**Step 7: 编译验证**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

期望：无 error。

**Step 8: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "fix: split _scheduleChunk into _startPrefetch/_waitForChunk to enable true parallel prefetch"
```

---

### Task 5: 清理 `_serveParallel` 的 try-finally 结构

**Files:**
- Modify: `lib/features/player/proxy/proxy_controller.dart`

Task 4 Step 5 中改了 serve 循环，但提前 return 时需要确保 `raf` 被正确关闭。确认 try-finally 结构如下：

```dart
final raf = await _cacheFile.open(mode: FileMode.read);
try {
  var offset = requested.start;
  final end = requested.end!;
  while (offset <= end) {
    final chunkReady = await _ensureChunkReady(offset ~/ chunkSize);
    if (!chunkReady || _mode == ProxyMode.single) {
      _degradeToSingle('chunk ${offset ~/ chunkSize} not ready during serve');
      // raf will be closed in finally
      break;  // 跳出循环，finally 关闭 raf，然后 fallback
    }
    final remaining = end - offset + 1;
    final readLen = min(remaining, 64 * 1024);
    await raf.setPosition(offset);
    final data = await raf.read(readLen);
    if (data.isEmpty) {
      throw StateError('cache data missing at offset=$offset after chunk ready');
    }
    _recordServedBytes(data.length);
    request.response.add(data);
    offset += data.length;
  }
} finally {
  await raf.close();
}

// Degrade fallback（在 try-finally 之后）
if (_mode == ProxyMode.single) {
  await _serveSingle(request, requested);
  return;
}
await request.response.close();
```

调整后将 `await request.response.close()` 移到 try-finally 之外，并在 degrade 情况下 `_serveSingle` 负责关闭 response。

**Step 1: 按上面结构调整 `_serveParallel` 的 try-finally**

确认 `_serveParallel` 末尾的 `await request.response.close()` 在正确位置。

**Step 2: 编译验证**

```bash
flutter analyze lib/features/player/proxy/proxy_controller.dart
```

**Step 3: Commit**

```bash
git add lib/features/player/proxy/proxy_controller.dart
git commit -m "fix: ensure raf is always closed via try-finally in _serveParallel"
```

---

### Task 6: 验证整体编译和运行

**Files:** 无新改动

**Step 1: 全项目分析**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter analyze
```

期望：无 error（warning/info 可接受）。

**Step 2: 检查引用了已删除接口的文件**

```bash
grep -rn "urlForPlaylist\|urlForSegment\|handlePlaylistRequest\|handleSegmentRequest\|onPlaylistRequest\|onSegmentRequest\|_probeMp4Init\|proxyUrl" lib/
```

期望：无输出（所有引用都已清理）。

**Step 3: 检查 player_page 和 media_kit_player_controller**

```bash
grep -n "proxyUrl\|urlForPlaylist\|ProxyMode\|proxySession" lib/features/player/player_page.dart lib/features/player/media_kit_player_controller.dart
```

确认这些文件使用的是 `playbackUrl`（`streamUrl`），而非已删除的 `proxyUrl`。

**Step 4: Final commit（如有遗漏的清理）**

```bash
git add -p
git commit -m "chore: final cleanup after proxy HLS removal"
```
