# Mobile Layout Design: Responsive Navigation

**Date:** 2026-02-23
**Status:** Approved

## Problem

The current `AppShell` uses a fixed left sidebar that is not suitable for narrow/portrait screens (mobile devices). The sidebar takes up too much horizontal space on narrow screens.

## Solution

Use `MediaQuery` width-based breakpoints (Material 3 adaptive layout convention) to switch between:

- **Wide screen (≥ 600px):** Left sidebar (current behavior)
- **Narrow screen (< 600px):** Bottom `NavigationBar` (Material 3)

## Design Details

### Breakpoint

```dart
final isWideScreen = MediaQuery.of(context).size.width >= 600;
```

600px is the Material 3 compact/medium breakpoint.

### Wide Screen Layout

```
Scaffold
  body: Row
    Sidebar (min 180px, 15% of screen) | child (Expanded)
```

### Narrow Screen Layout

```
Scaffold
  bottomNavigationBar: NavigationBar(...)
  body: child
```

### NavigationBar Styling

- `backgroundColor`: `Color(0xFF192233)` — matches sidebar background
- Selected indicator color: `Color(0xFFF47B25)` — matches sidebar selection
- Selected icon/label color: `Color(0xFFF47B25)`
- Unselected icon/label color: `Colors.white70`
- `NavigationDestination` items sourced from `AppRoutes.menuItems`

### Selected Index Sync

```dart
final selectedIndex = AppRoutes.menuItems
    .indexWhere((item) => item.route == currentRoute);
```

`onDestinationSelected` calls `_onMenuTap(context, AppRoutes.menuItems[index].route)`.

## Files Changed

- `lib/app/app_shell.dart` — only file modified

## Trade-offs

- Breakpoint is width-based (not orientation-based), so a wide tablet in portrait mode still gets the sidebar — this is intentional and aligns with Material 3 adaptive layout guidelines.
- No new files created; complexity stays in one widget.
