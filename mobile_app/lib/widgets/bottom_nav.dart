import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

class BottomNavItem {
  final IconData icon;
  final IconData? activeIcon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  const BottomNavItem({
    required this.icon,
    this.activeIcon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });
}

/// Floating frosted-glass bottom bar: every tab shows its icon and label,
/// the active one sits on a soft tinted highlight, and a raised circular
/// button floats in the middle for the primary action (Explore).
///
/// [items] must have an even count; the center button is placed between
/// the two halves.
class FloatingBottomNav extends StatelessWidget {
  final List<BottomNavItem> items;
  final BottomNavItem center;

  const FloatingBottomNav({super.key, required this.items, required this.center})
      : assert(items.length % 2 == 0);

  @override
  Widget build(BuildContext context) {
    // Deliberately avoids SafeArea+Center here: that combination inside
    // Scaffold.bottomNavigationBar collapses the Scaffold body to zero
    // height on the web (CanvasKit) target -- reproduced and isolated to
    // that specific nesting. Reading the bottom inset directly gets the same
    // safe-area behavior SafeArea would have given.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final dark = AppTheme.instance.isDark;
    final half = items.length ~/ 2;

    return Padding(
      padding: EdgeInsets.fromLTRB(
          14, 0, 14, bottomInset > 10 ? bottomInset : 10),
      child: SizedBox(
        height: 88,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: Container(
                  height: 70,
                  decoration: BoxDecoration(
                    color: AppColors.glassBg,
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: AppColors.glassBorder),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: dark ? 0.09 : 0.35),
                        Colors.white.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.6],
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                  child: Row(
                    children: [
                      for (final item in items.take(half))
                        Expanded(child: _NavTab(item: item)),
                      const SizedBox(width: 72),
                      for (final item in items.skip(half))
                        Expanded(child: _NavTab(item: item)),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(top: 0, child: _CenterButton(item: center)),
          ],
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  final BottomNavItem item;
  const _NavTab({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = item.active ? AppColors.red : AppColors.muted;
    return Semantics(
      button: true,
      selected: item.active,
      label: item.tooltip,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: item.active
                ? AppColors.red.withValues(alpha: 0.14)
                : Colors.transparent,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.active ? (item.activeIcon ?? item.icon) : item.icon,
                  size: 22, color: color),
              const SizedBox(height: 3),
              Text(
                item.tooltip,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(
                    size: 10.5,
                    weight: item.active ? FontWeight.w700 : FontWeight.w500,
                    color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenterButton extends StatelessWidget {
  final BottomNavItem item;
  const _CenterButton({required this.item});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: item.tooltip,
      child: Tooltip(
        message: item.tooltip,
        child: GestureDetector(
          onTap: item.onTap,
          child: Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.red, const Color(0xFF9E3A14)],
              ),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.28), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: AppColors.red.withValues(alpha: 0.45),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(item.icon, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }
}
