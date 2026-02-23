# Player Page Mobile Portrait Adaptation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a portrait-mode layout to `player_page.dart` — full-width video (no card), no top navigation bar, compact inline controls, and a 4-column episode grid below — all in a single scrollable page.

**Architecture:** Detect portrait with `size.width < size.height && size.width < 600` inside `build()`. When portrait, render a new `_buildPortraitBody()` that returns a `CustomScrollView`. Otherwise, keep the existing desktop/landscape layout completely unchanged. All playback state, auth recovery, and stream subscriptions are untouched.

**Tech Stack:** Flutter, media_kit_video (`MaterialDesktopVideoControlsTheme`, `Video`)

---

### Task 1: Add portrait detection and routing in `build()`

**Files:**
- Modify: `lib/features/player/player_page.dart` — `build()` method (~line 1484)

**Context:**
The existing `build()` method returns a Scaffold containing `_buildTopNavigation()` + `LayoutBuilder` with `_buildVideoPlayerArea()`. We need to branch before rendering the Scaffold body.

**Step 1: Locate the `build` method**

Open `lib/features/player/player_page.dart`, find the `build` method starting around line 1484. The main Scaffold body is:
```dart
body: SafeArea(
  child: Column(
    children: [
      _buildTopNavigation(),
      Expanded(child: LayoutBuilder(...)),
    ],
  ),
),
```

**Step 2: Add portrait detection and branch**

Replace the final `return Scaffold(...)` (the non-loading, non-error path, starting ~line 1534) with:

```dart
final size = MediaQuery.of(context).size;
final isPortrait = size.width < size.height && size.width < 600;

if (isPortrait) {
  return Scaffold(
    backgroundColor: const Color(0xFF101622),
    body: SafeArea(child: _buildPortraitBody()),
  );
}

return Scaffold(
  backgroundColor: const Color(0xFF101622),
  body: SafeArea(
    child: Column(
      children: [
        _buildTopNavigation(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showSidebar = constraints.maxWidth >= 1000;
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildVideoPlayerArea()),
                    if (showSidebar) ...[
                      const SizedBox(width: 24),
                      SizedBox(width: 400, child: _buildSidebarArea()),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
  ),
);
```

**Step 3: Add a stub `_buildPortraitBody()` to compile**

Below `_buildSidebarArea()` (around line 1481), add:

```dart
Widget _buildPortraitBody() {
  return const Center(child: Text('portrait', style: TextStyle(color: Colors.white)));
}
```

**Step 4: Hot reload and verify**

Run the app on a narrow phone simulator (e.g. iPhone SE, 375pt wide). The player page should show "portrait" text. On a wide screen or landscape it should show the existing layout.

**Step 5: Commit**

```bash
git add lib/features/player/player_page.dart
git commit -m "feat: add portrait detection branch in PlayerPage.build"
```

---

### Task 2: Implement `_buildPortraitBody()` — video sliver

**Files:**
- Modify: `lib/features/player/player_page.dart` — replace stub `_buildPortraitBody()`

**Context:**
The desktop `_buildVideoPlayerArea()` wraps the video in a `Container` with `borderRadius: 12`, `boxShadow`, and a card-style border. Portrait should have the video flush to the screen edges with `AspectRatio(16/9)`, no card decoration.

**Step 1: Replace the stub with a `CustomScrollView` containing just the video sliver**

```dart
Widget _buildPortraitBody() {
  return CustomScrollView(
    slivers: [
      // ── Video ──────────────────────────────────────────────────
      SliverToBoxAdapter(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              children: [
                MaterialDesktopVideoControlsTheme(
                  normal: MaterialDesktopVideoControlsThemeData(
                    topButtonBar: _buildTopButtonBar(),
                    bottomButtonBar: _buildBottomButtonBar(),
                  ),
                  fullscreen: MaterialDesktopVideoControlsThemeData(
                    topButtonBar: _buildTopButtonBar(),
                    bottomButtonBar: _buildBottomButtonBar(),
                  ),
                  child: Video(controller: _videoController),
                ),
                if (_isBufferingNow)
                  Positioned(
                    top: 16,
                    right: 16,
                    child: IgnorePointer(
                      child: Text(
                        _networkStatsText(),
                        style: const TextStyle(
                          color: Color(0xFFFFB37A),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(color: Colors.black, blurRadius: 8)],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),

      // placeholder for controls + episodes (next tasks)
      const SliverToBoxAdapter(child: SizedBox(height: 200)),
    ],
  );
}
```

**Step 2: Hot reload and verify**

The video should appear full-width at the top on a portrait device, no rounded corners. Controls in the video overlay should still work (play/pause, seek bar). The placeholder 200px space sits below.

**Step 3: Commit**

```bash
git add lib/features/player/player_page.dart
git commit -m "feat: portrait video sliver — full-width, no card wrapper"
```

---

### Task 3: Add compact controls sliver

**Files:**
- Modify: `lib/features/player/player_page.dart` — inside `_buildPortraitBody()`, replace the placeholder

**Context:**
Desktop has a `Container` card below the video with `_showResolutionPicker` (线路清晰度) and `_showCloudResolutionPicker` (网盘清晰度) buttons + icon buttons. Portrait shows the same buttons in a compact horizontal row, no card container.

**Step 1: Replace `SliverToBoxAdapter(child: SizedBox(height: 200))` with controls + episodes slivers**

Replace that single placeholder sliver with:

```dart
      // ── Controls ───────────────────────────────────────────────
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: _showResolutionPicker,
                icon: const Icon(Icons.dns, size: 16, color: Color(0xFFF47B25)),
                label: Text(
                  _currentPlayingEpisode?.displayResolution ?? '线路1',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  side: const BorderSide(color: Color(0xFF2E3B56)),
                  backgroundColor: const Color(0xFF101622),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _currentMedia?.variants.isNotEmpty == true
                    ? _showCloudResolutionPicker
                    : null,
                icon: const Icon(
                  Icons.high_quality_rounded,
                  size: 16,
                  color: Color(0xFFF47B25),
                ),
                label: Text(
                  _currentCloudVariant != null
                      ? _cloudResolutionLabel(_currentCloudVariant!)
                      : '网盘清晰度',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  side: const BorderSide(color: Color(0xFF2E3B56)),
                  backgroundColor: const Color(0xFF101622),
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.favorite_border, color: Colors.white70, size: 20),
                onPressed: () {},
                tooltip: '加入收藏',
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(6),
              ),
              IconButton(
                icon: const Icon(Icons.share, color: Colors.white70, size: 20),
                onPressed: () {},
                tooltip: '分享',
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(6),
              ),
            ],
          ),
        ),
      ),
```

**Step 2: Hot reload and verify**

Below the video, a row of two outlined buttons (线路1 / 网盘清晰度) appears on the left, two icon buttons on the right. Tapping the buttons should open the existing bottom sheets (resolution picker).

**Step 3: Commit**

```bash
git add lib/features/player/player_page.dart
git commit -m "feat: portrait compact controls sliver below video"
```

---

### Task 4: Add episode grid sliver (4 columns)

**Files:**
- Modify: `lib/features/player/player_page.dart` — inside `_buildPortraitBody()`, append after controls sliver

**Context:**
The desktop sidebar `_buildSidebarArea()` contains a `GridView` with `crossAxisCount: 5`. Portrait gets its own episode grid inline in the scroll view with `crossAxisCount: 4`. The tap logic is identical to the sidebar's grid.

**Step 1: Append the episode sliver after the controls sliver**

```dart
      // ── Episode grid ───────────────────────────────────────────
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(color: Color(0xFF232F48)),
              const SizedBox(height: 8),
              const Text(
                '剧集列表',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              if (_groupKeys.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('未找到剧集', style: TextStyle(color: Colors.white70)),
                  ),
                )
              else
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1,
                  ),
                  itemCount: _groupKeys.length,
                  itemBuilder: (context, index) {
                    final key = _groupKeys[index];
                    final isPlaying = key == _currentGroupKey;
                    final episodesInGroup = _groupedEpisodes[key] ?? [];
                    final baseEpisode = episodesInGroup.firstOrNull;

                    return InkWell(
                      onTap: () {
                        final prepared = _preparedSelection;
                        if (prepared == null) return;
                        if (episodesInGroup.isNotEmpty && !isPlaying) {
                          _playParsedEpisode(prepared, episodesInGroup.first);
                        }
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: isPlaying
                              ? const Color(0xFFF47B25)
                              : const Color(0xFF1A2332),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isPlaying
                                ? Colors.transparent
                                : const Color(0xFF2E3B56),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: isPlaying
                            ? const Icon(Icons.equalizer, color: Colors.white, size: 20)
                            : FittedBox(
                                child: Padding(
                                  padding: const EdgeInsets.all(4.0),
                                  child: Text(
                                    baseEpisode?.displayTitle ?? '${index + 1}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
```

**Step 2: Hot reload and verify**

- Scroll down on portrait: "剧集列表" header appears, then a 4-column grid of episode buttons.
- Tapping an episode button triggers `_playParsedEpisode`.
- Currently playing episode shows orange highlight with `Icons.equalizer`.
- Empty state shows "未找到剧集".

**Step 3: Commit**

```bash
git add lib/features/player/player_page.dart
git commit -m "feat: portrait episode grid (4 columns) sliver"
```

---

### Task 5: Final verification and polish

**No code changes** — just verification steps.

**Step 1: Test portrait layout end-to-end**

1. Open player page on a narrow device/simulator (width < height, width < 600pt).
2. Confirm: no top navigation bar.
3. Confirm: video is full-width, no rounded corners, no card shadow.
4. Confirm: controls row appears immediately below video.
5. Confirm: tapping 线路清晰度 / 网盘清晰度 buttons opens bottom sheets.
6. Confirm: episode grid shows in 4 columns, currently playing episode is highlighted orange.
7. Confirm: tapping episode grid item starts playback.
8. Confirm: page scrolls smoothly; video stays at top.

**Step 2: Test landscape / wide screen unchanged**

1. Rotate to landscape or run on a wide screen.
2. Confirm: top navigation bar is present.
3. Confirm: video is in a card with rounded corners and shadow.
4. Confirm: sidebar appears when width >= 1000.

**Step 3: Test buffering overlay**

While buffering, confirm the network speed text overlay appears top-right of the video in both portrait and landscape.

**Step 4: Final commit if any polish fixes were needed**

```bash
git add lib/features/player/player_page.dart
git commit -m "fix: portrait layout polish"
```
