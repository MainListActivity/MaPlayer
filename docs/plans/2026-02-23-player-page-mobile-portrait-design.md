# Player Page — Mobile Portrait Mode Design

**Date:** 2026-02-23
**Status:** Approved

## Summary

Add mobile portrait mode adaptation to `player_page.dart`.
Portrait is defined as: `width < height && width < 600`.

## Goals

- Hide the top navigation bar on portrait
- Display the video full-width with no card/rounded-corner wrapper
- Show a compact control bar (resolution buttons) below the video
- Show an episode grid (4 columns) below the controls
- The whole page scrolls vertically
- Landscape / wide-screen layout is unchanged

## Layout Structure (Portrait)

```
Scaffold (backgroundColor: #101622)
└── SafeArea
    └── CustomScrollView
        ├── SliverToBoxAdapter — Video area
        │   └── AspectRatio(16:9) + Stack
        │       ├── MaterialDesktopVideoControlsTheme + Video
        │       └── Buffering speed overlay (top-right)
        ├── SliverToBoxAdapter — Control bar
        │   └── Padding(h:16, v:12)
        │       └── Row
        │           ├── OutlinedButton (线路清晰度)
        │           ├── SizedBox(8)
        │           ├── OutlinedButton (网盘清晰度)
        │           └── Spacer + Row (favorite / share / report icons)
        └── SliverToBoxAdapter — Episode grid
            └── Padding(16)
                ├── Text "剧集列表" header
                └── GridView(crossAxisCount: 4, childAspectRatio: 1)
```

## Key Decisions

| Topic | Decision |
|---|---|
| Portrait detection | `width < height && width < 600` |
| Approach | Branch in `build()`, two independent layout paths |
| Video wrapper | No card, no border-radius, no shadow — full bleed |
| Control bar | Horizontal row, compact, inline |
| Episode grid | 4 columns (down from desktop's 5) |
| Scroll | Full page `CustomScrollView` |
| Top nav | Not rendered in portrait |
| Player controls | Reuse `MaterialDesktopVideoControlsTheme` (same as desktop) |

## Unchanged

- Landscape / wide-screen (`width >= 600` or `width >= height`) keeps existing layout
- `_buildTopNavigation`, `_buildVideoPlayerArea`, `_buildSidebarArea` methods unchanged
- All playback logic, state management, auth recovery — untouched

## Implementation Notes

- New method `_buildPortraitBody()` returns the `CustomScrollView`
- Episode grid in portrait reuses same tap logic as `_buildSidebarArea`
- No new dependencies required
