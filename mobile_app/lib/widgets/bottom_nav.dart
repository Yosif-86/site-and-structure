import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

class BottomNavItem {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  const BottomNavItem({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });
}

/// Floating glass pill-shaped bottom navigation bar. The active item expands
/// into a filled label pill (icon + text); inactive items stay icon-only, so
/// the bar's overall width breathes with whichever tab is selected instead
/// of every label competing for space at once.
class FloatingBottomNav extends StatelessWidget {
  final List<BottomNavItem> items;

  const FloatingBottomNav({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    // Deliberately avoids SafeArea+Center here: that combination inside
    // Scaffold.bottomNavigationBar collapses the Scaffold body to zero
    // height on the web (CanvasKit) target — reproduced and isolated to
    // that specific nesting. Row+mainAxisAlignment.center gets the same
    // centered pill without it, and reading the bottom inset directly
    // gets the same safe-area behavior SafeArea would have given.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset > 12 ? bottomInset : 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.glassBg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppColors.glassBorder),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 20,
                        offset: const Offset(0, 8)),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (final item in items) _NavPill(item: item)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavPill extends StatelessWidget {
  final BottomNavItem item;
  const _NavPill({required this.item});

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.instance.isDark;
    // The active pill fills solid so it reads at a glance against the
    // frosted bar behind it — white-on-black in dark mode, the inverse in
    // light mode, same swap the rest of the theme does at the palette level.
    final activeBg = dark ? Colors.white : AppColors.text;
    final activeFg = dark ? Colors.black : AppColors.bg;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Tooltip(
        message: item.tooltip,
        child: InkWell(
          onTap: item.onTap,
          borderRadius: BorderRadius.circular(999),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            height: 44,
            padding: EdgeInsets.symmetric(horizontal: item.active ? 16 : 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: item.active ? activeBg : Colors.transparent,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(item.icon,
                    size: 20, color: item.active ? activeFg : AppColors.muted),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: item.active
                      ? Padding(
                          padding: const EdgeInsetsDirectional.only(start: 8),
                          child: Text(
                            item.tooltip,
                            style: AppFonts.body(
                                size: 13.5,
                                weight: FontWeight.w600,
                                color: activeFg),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
