# 播放进度记忆功能设计

**日期：** 2026-02-23
**状态：** 已批准

## 需求

用户播放历史除记录播放到第几集外，还需记录播放到该集的第几分钟。再次打开同一影片时，自动跳转到上次观看的时间位置。

## 决策

- 保存时机：用户离开播放器时（`dispose`），不做周期性保存
- 接近片尾时：仍跳转到保存的位置，不重置（用户可手动从头播放）

## 方案选择

采用**方案 A**：在 `PlayHistoryItem` 增加 `lastPositionMs` 字段，在 `PlayerPage.dispose()` 时保存。

其他方案：
- 方案 B（每集独立记录进度）：改动更多，cachedEpisodes 语义混用
- 方案 C（独立 PositionRepository）：数据一致性难维护

## 架构设计

### 数据层：`play_history_models.dart`

`PlayHistoryItem` 增加字段：

```dart
final int? lastPositionMs;
```

- `toJson`：写入 `'lastPositionMs': lastPositionMs`
- `fromJson`：`json['lastPositionMs'] as int?`（null 表示无记录，向后兼容）
- `copyWith`：使用 `Object?` 哨兵参数处理显式传 null 的情况

### 保存逻辑：`player_page.dart`

`_PlayerPageState` 持有 `PlayHistoryRepository` 实例（与 orchestrator 共用）。

`dispose()` 时，若有 share request：
1. 读 `_playerController.player.state.position.inMilliseconds`
2. `findByShareUrl` 取当前记录
3. `copyWith(lastPositionMs: posMs)` 后 upsert
4. 用 `unawaited(...)` 包裹异步调用

### 恢复位置：`_openMedia()` in `player_page.dart`

在现有 proxy seek 逻辑的同级位置增加时间 seek：

```dart
// progressKey 格式为 '${shareUrl}:${fileId}'
// 仅当当前打开的 episode 与 history 记录一致时才恢复
final posMs = history?.lastPositionMs ?? 0;
if (posMs > 0) {
  final duration = await _waitForDuration();
  if (duration > Duration.zero) {
    await _playerController.player.seek(Duration(milliseconds: posMs));
  }
}
```

history 通过 `_preparedSelection` 中已有的 shareUrl 查询，或在 `_openMedia` 时通过 `media.progressKey` 解析。

### UI：`history_page.dart`

历史卡片副标题扩展显示进度：

```
第3集 · 12:34
```

格式：`lastEpisodeName ?? '点击选集'`，若 `lastPositionMs > 0` 则追加 ` · mm:ss`。

## 文件改动清单

| 文件 | 改动 |
|------|------|
| `lib/features/history/play_history_models.dart` | 增加 `lastPositionMs` 字段 |
| `lib/features/player/player_page.dart` | dispose 时保存位置；`_openMedia` 时恢复位置 |
| `lib/features/history/history_page.dart` | 卡片副标题显示进度时间 |
