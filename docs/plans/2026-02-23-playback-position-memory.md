# 播放进度记忆 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在用户播放历史中记录每集的播放时间位置，再次打开同一影片时自动跳转到上次观看位置。

**Architecture:** 在 `PlayHistoryItem` 增加 `lastPositionMs` 字段（可空 int）存储毫秒级播放位置；`PlayerPage.dispose()` 时异步保存当前播放位置；`_openMedia()` 中在打开与历史记录一致的集数时自动 seek；历史页卡片显示格式化的进度时间。

**Tech Stack:** Flutter, media_kit, shared_preferences（已有）

---

### Task 1: 在数据模型中增加 `lastPositionMs` 字段

**Files:**
- Modify: `lib/features/history/play_history_models.dart`

**Step 1: 增加字段、copyWith、toJson、fromJson**

打开 `lib/features/history/play_history_models.dart`，按以下方式修改 `PlayHistoryItem`：

```dart
class PlayHistoryItem {
  const PlayHistoryItem({
    required this.shareUrl,
    required this.pageUrl,
    required this.title,
    required this.coverUrl,
    this.coverHeaders = const <String, String>{},
    required this.intro,
    required this.showDirName,
    this.showFolderId,
    required this.updatedAtEpochMs,
    this.lastEpisodeFileId,
    this.lastEpisodeName,
    this.lastPositionMs,           // 新增
    this.cachedEpisodes = const <PlayHistoryEpisode>[],
  });

  // ... 已有字段 ...
  final int? lastPositionMs;       // 新增
```

`copyWith` 方法中，用 `Object?` 哨兵支持显式传 null：

```dart
PlayHistoryItem copyWith({
  // ... 已有参数 ...
  Object? lastPositionMs = _sentinel,  // 新增
}) {
  return PlayHistoryItem(
    // ... 已有字段 ...
    lastPositionMs: lastPositionMs == _sentinel
        ? this.lastPositionMs
        : lastPositionMs as int?,      // 新增
  );
}

static const Object _sentinel = Object();
```

`toJson` 增加：
```dart
'lastPositionMs': lastPositionMs,
```

`fromJson` 增加：
```dart
lastPositionMs: (json['lastPositionMs'] as num?)?.toInt(),
```

**Step 2: 验证编译通过**

```bash
flutter analyze lib/features/history/play_history_models.dart
```
预期：无错误

**Step 3: Commit**

```bash
git add lib/features/history/play_history_models.dart
git commit -m "feat: add lastPositionMs field to PlayHistoryItem"
```

---

### Task 2: 在 PlayerPage 中保存播放位置

**Files:**
- Modify: `lib/features/player/player_page.dart`

**Step 1: 注入 `PlayHistoryRepository`**

在 `_PlayerPageState` 顶部增加字段：

```dart
final _historyRepository = PlayHistoryRepository();
```

在文件顶部已有 `import 'package:ma_palyer/features/history/play_history_repository.dart';`（通过 orchestrator 间接引用，需确认是否已导入，如没有则添加）。

**Step 2: 在 `dispose()` 中保存位置**

在现有 `dispose()` 方法中，在 `super.dispose()` 之前添加保存逻辑：

```dart
@override
void dispose() {
  _bufferingSub?.cancel();
  _completedSub?.cancel();
  _playerLogSub?.cancel();
  _playerErrorSub?.cancel();
  _proxyStatsSub?.cancel();
  final sessionId = _proxySessionId;
  if (sessionId != null) {
    unawaited(ProxyController.instance.closeSession(sessionId));
  }
  unawaited(ProxyController.instance.dispose());

  // 新增：保存播放位置
  final prepared = _preparedSelection;
  final currentEpisode = _currentPlayingEpisode;
  if (prepared != null && currentEpisode != null) {
    final posMs = _playerController.player.state.position.inMilliseconds;
    if (posMs > 0) {
      unawaited(_savePlaybackPosition(
        shareUrl: prepared.request.shareUrl,
        positionMs: posMs,
      ));
    }
  }

  _playerController.dispose();
  super.dispose();
}
```

**Step 3: 实现 `_savePlaybackPosition` 方法**

在 `_PlayerPageState` 中添加私有方法：

```dart
Future<void> _savePlaybackPosition({
  required String shareUrl,
  required int positionMs,
}) async {
  final current = await _historyRepository.findByShareUrl(shareUrl);
  if (current == null) return;
  await _historyRepository.upsertByShareUrl(
    current.copyWith(lastPositionMs: positionMs),
  );
}
```

**Step 4: 验证编译通过**

```bash
flutter analyze lib/features/player/player_page.dart
```
预期：无错误

**Step 5: Commit**

```bash
git add lib/features/player/player_page.dart
git commit -m "feat: save playback position to history on player dispose"
```

---

### Task 3: 在 PlayerPage 中恢复播放位置

**Files:**
- Modify: `lib/features/player/player_page.dart`

**Step 1: 在 `_PlayerPageState` 中持有 history 引用**

在 `_prepareAndPlayFromShare` 中，`prepared` 已包含 `preferredFileId`（上次播放的集数），history 可通过 `_historyRepository.findByShareUrl` 查询。

在 `_openMedia` 方法中，现有逻辑已处理 proxy 的 byte-offset seek。在此之后（`if (restoredBytes != null ...)` 块之后），增加时间维度的 seek：

```dart
// 恢复时间进度（仅当当前集与历史记录一致时）
final prepared = _preparedSelection;
final currentEpisode = _currentPlayingEpisode;
if (prepared != null && currentEpisode != null) {
  final history = await _historyRepository.findByShareUrl(
    prepared.request.shareUrl,
  );
  final lastFileId = history?.lastEpisodeFileId;
  final posMs = history?.lastPositionMs ?? 0;
  // media.progressKey 格式为 '${shareUrl}:${fileId}'
  final expectedKey =
      '${prepared.request.shareUrl}:${currentEpisode.file.fid}';
  if (posMs > 0 &&
      lastFileId == currentEpisode.file.fid &&
      media.progressKey == expectedKey) {
    final duration = await _waitForDuration();
    if (!mounted) return;
    if (duration > Duration.zero) {
      await _playerController.player.seek(
        Duration(milliseconds: posMs),
      );
    }
  }
}
```

注意：将此代码块插入在现有 `if (prevSessionId != null && ...)` 之前，且在 `if (restoredBytes != null ...)` 块之后。

**Step 2: 验证编译通过**

```bash
flutter analyze lib/features/player/player_page.dart
```
预期：无错误

**Step 3: Commit**

```bash
git add lib/features/player/player_page.dart
git commit -m "feat: restore playback position on episode open"
```

---

### Task 4: 历史页卡片显示进度时间

**Files:**
- Modify: `lib/features/history/history_page.dart`

**Step 1: 添加格式化时间的辅助函数**

在 `history_page.dart` 顶层（class 外部）添加：

```dart
String _formatPosition(int ms) {
  final total = Duration(milliseconds: ms);
  final h = total.inHours;
  final m = total.inMinutes.remainder(60);
  final s = total.inSeconds.remainder(60);
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}
```

**Step 2: 修改卡片副标题文本**

在 `_HistoryPageState.build` 中，找到：

```dart
Text(
  item.lastEpisodeName ?? '点击选集',
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: const TextStyle(
    color: Colors.white70,
    fontSize: 12,
  ),
),
```

替换为：

```dart
Text(
  () {
    final name = item.lastEpisodeName ?? '点击选集';
    final pos = item.lastPositionMs;
    if (pos != null && pos > 0) {
      return '$name · ${_formatPosition(pos)}';
    }
    return name;
  }(),
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: const TextStyle(
    color: Colors.white70,
    fontSize: 12,
  ),
),
```

**Step 3: 验证编译通过**

```bash
flutter analyze lib/features/history/history_page.dart
```
预期：无错误

**Step 4: Commit**

```bash
git add lib/features/history/history_page.dart
git commit -m "feat: show playback position in history card subtitle"
```

---

### Task 5: 全量分析验证

**Step 1: 运行全量静态分析**

```bash
flutter analyze
```
预期：No issues found（或仅有已存在的 info 级别提示）

**Step 2: 手动测试流程**

1. 打开一个影片，播放到某一时间点（如 5 分钟）
2. 按返回键退出播放器
3. 在历史页确认该条目显示 `第X集 · 05:00`
4. 再次点击该历史条目进入播放器
5. 确认视频自动从 5 分钟处开始播放

**Step 3: 最终 Commit（如有未提交内容）**

```bash
git status
# 确认无未提交改动
```
