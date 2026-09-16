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

/// Floating pill-shaped bottom navigation bar (replaces the old side Drawer).
class FloatingBottomNav extends StatelessWidget {
  final List<BottomNavItem> items;

  const FloatingBottomNav({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.only(bottom: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.glassBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.glassBorder),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 18, offset: const Offset(0, 8)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items) _NavIcon(item: item),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavIcon extends StatelessWidget {
  final BottomNavItem item;
  const _NavIcon({required this.item});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: item.tooltip,
        child: InkWell(
          onTap: item.onTap,
          borderRadius: BorderRadius.circular(999),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: item.active
                  ? LinearGradient(colors: [AppColors.red, AppColors.red.withValues(alpha: 0.75)])
                  : null,
            ),
            child: Icon(
              item.icon,
              color: item.active ? Colors.white : AppColors.muted,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}
