# Mobile Layout Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `AppShell` responsive — sidebar on wide screens (≥ 600px), Material 3 `NavigationBar` at bottom on narrow screens.

**Architecture:** Single file change in `lib/app/app_shell.dart`. A width check via `MediaQuery` determines which navigation mode to render. Wide: existing `Row(Sidebar + child)`. Narrow: `Scaffold(bottomNavigationBar: NavigationBar, body: child)`.

**Tech Stack:** Flutter, Material 3 (`NavigationBar`, `NavigationDestination`)

---

### Task 1: Add `_buildBottomNav` method to `AppShell`

**Files:**
- Modify: `lib/app/app_shell.dart`

This task adds the bottom navigation bar widget method to `AppShell`, keeping it inactive (not yet wired into `build`).

**Step 1: Read the current file**

Read `lib/app/app_shell.dart` to understand current structure before making changes.

**Step 2: Add `_buildBottomNav` method after `_buildSidebar`**

Insert the following method between `_buildSidebar` and the `build` method (around line 100, after the closing `}` of `_buildSidebar`):

```dart
Widget _buildBottomNav(BuildContext context) {
  final selectedIndex = AppRoutes.menuItems
      .indexWhere((item) => item.route == currentRoute)
      .clamp(0, AppRoutes.menuItems.length - 1);

  return NavigationBar(
    backgroundColor: const Color(0xFF192233),
    indicatorColor: const Color(0xFFF47B25).withOpacity(0.20),
    selectedIndex: selectedIndex,
    onDestinationSelected: (index) =>
        _onMenuTap(context, AppRoutes.menuItems[index].route),
    destinations: AppRoutes.menuItems.map((item) {
      final selected = item.route == currentRoute;
      return NavigationDestination(
        icon: Icon(
          item.icon,
          color: selected ? const Color(0xFFF47B25) : Colors.white70,
        ),
        label: item.label,
      );
    }).toList(),
    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
  );
}
```

**Step 3: Hot-reload and verify no compile errors**

Run: `flutter analyze lib/app/app_shell.dart`

Expected: no errors or only style hints. If `withOpacity` causes a deprecation warning in newer Flutter, replace with `.withValues(alpha: 0.20)`.

**Step 4: Commit**

```bash
git add lib/app/app_shell.dart
git commit -m "feat: add _buildBottomNav method to AppShell"
```

---

### Task 2: Update `build` to switch between sidebar and bottom nav based on screen width

**Files:**
- Modify: `lib/app/app_shell.dart`

**Step 1: Replace the `build` method**

Find and replace the current `build` method:

```dart
// OLD — replace this entire method:
@override
Widget build(BuildContext context) {
  return Scaffold(
    body: Row(
      children: [
        _buildSidebar(context),
        Expanded(child: child),
      ],
    ),
  );
}
```

With:

```dart
@override
Widget build(BuildContext context) {
  final isWideScreen = MediaQuery.of(context).size.width >= 600;

  if (isWideScreen) {
    return Scaffold(
      body: Row(
        children: [
          _buildSidebar(context),
          Expanded(child: child),
        ],
      ),
    );
  }

  return Scaffold(
    bottomNavigationBar: _buildBottomNav(context),
    body: child,
  );
}
```

**Step 2: Run Flutter analyze**

Run: `flutter analyze lib/app/app_shell.dart`

Expected: no errors.

**Step 3: Hot reload and verify visually**

- On a wide window (≥ 600px): left sidebar appears as before.
- Resize window to < 600px (or run on a phone emulator): bottom nav bar appears, sidebar disappears.
- Tap each bottom nav item: navigates correctly to 首页 / 历史 / 设置.
- The active item shows the orange (`0xFFF47B25`) icon color.

**Step 4: Commit**

```bash
git add lib/app/app_shell.dart
git commit -m "feat: switch AppShell to bottom NavigationBar on narrow screens"
```

---

### Task 3: Verify `NavigationBar` theme color overrides (optional cleanup)

**Files:**
- Modify: `lib/app/app_shell.dart` (if needed)

Flutter's `NavigationBar` uses the theme's `colorScheme` for label colors. The icon colors are set explicitly via the `icon` parameter above, but the label text color may default to the theme color.

**Step 1: Check label text color on narrow screen**

Run the app on a narrow screen. Inspect whether the selected label text is orange and unselected is `white70`.

**Step 2: If label colors don't match, add `NavigationBarThemeData` override**

If label colors are wrong, wrap `NavigationBar` in a `Theme` widget:

```dart
Widget _buildBottomNav(BuildContext context) {
  final selectedIndex = AppRoutes.menuItems
      .indexWhere((item) => item.route == currentRoute)
      .clamp(0, AppRoutes.menuItems.length - 1);

  return Theme(
    data: Theme.of(context).copyWith(
      navigationBarTheme: NavigationBarThemeData(
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected ? const Color(0xFFF47B25) : Colors.white70,
            fontSize: 12,
            fontWeight: selected ? FontWeight.bold : FontWeight.w500,
          );
        }),
      ),
    ),
    child: NavigationBar(
      backgroundColor: const Color(0xFF192233),
      indicatorColor: const Color(0xFFF47B25).withOpacity(0.20),
      selectedIndex: selectedIndex,
      onDestinationSelected: (index) =>
          _onMenuTap(context, AppRoutes.menuItems[index].route),
      destinations: AppRoutes.menuItems.map((item) {
        final selected = item.route == currentRoute;
        return NavigationDestination(
          icon: Icon(
            item.icon,
            color: selected ? const Color(0xFFF47B25) : Colors.white70,
          ),
          label: item.label,
        );
      }).toList(),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
  );
}
```

**Step 3: Run Flutter analyze**

Run: `flutter analyze lib/app/app_shell.dart`

Expected: no errors.

**Step 4: Commit (only if changes were made)**

```bash
git add lib/app/app_shell.dart
git commit -m "fix: apply NavigationBar label color overrides for dark theme"
```

---

## Done

All changes are in `lib/app/app_shell.dart`. No other files modified.

**Manual verification checklist:**
- [ ] Wide window (≥ 600px): sidebar visible, no bottom nav
- [ ] Narrow window (< 600px): bottom nav visible, no sidebar
- [ ] All 3 nav items navigate correctly
- [ ] Active item is highlighted in orange
- [ ] App resizes smoothly when window is dragged between widths
