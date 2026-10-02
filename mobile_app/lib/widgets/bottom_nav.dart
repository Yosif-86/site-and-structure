import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'arc_icons.dart';

class BottomNavItem {
  final ArcIcon icon;
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

/// Floating frosted-glass bottom bar. Every tab shows its Arc line icon and
/// label; a tinted glass lens slides under the active tab (its icon turns
/// duotone orange with a small glowing bar beneath), and a raised orange
/// rounded-square button in the middle opens Explore.
///
/// [items] must have an even count; the center button is placed between
/// the two halves.
class FloatingBottomNav extends StatelessWidget {
  final List<BottomNavItem> items;
  final BottomNavItem center;

  const FloatingBottomNav({super.key, required this.items, required this.center})
      : assert(items.length % 2 == 0);

  static const _barHeight = 70.0;
  static const _gap = 74.0;
  static const _pad = 6.0;

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
    final activeIndex = items.indexWhere((i) => i.active);

    return Padding(
      padding: EdgeInsets.fromLTRB(
          14, 0, 14, bottomInset > 10 ? bottomInset : 10),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          // Tablets: keep the bar a comfortable thumb-width, not edge to edge.
          constraints: const BoxConstraints(maxWidth: 520),
          child: SizedBox(
            height: 90,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                    child: Container(
                      height: _barHeight,
                      decoration: BoxDecoration(
                        color: AppColors.glassBg,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(color: AppColors.glassBorder),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(alpha: dark ? 0.10 : 0.55),
                            Colors.white.withValues(alpha: dark ? 0.02 : 0.15),
                          ],
                        ),
                      ),
                      padding: const EdgeInsets.all(_pad),
                      child: LayoutBuilder(builder: (context, c) {
                        final tabW = (c.maxWidth - _gap) / items.length;
                        double startOf(int i) =>
                            i < half ? i * tabW : i * tabW + _gap;
                        return Stack(
                          children: [
                            if (activeIndex >= 0)
                              AnimatedPositionedDirectional(
                                duration: const Duration(milliseconds: 360),
                                curve: Curves.easeOutBack,
                                start: startOf(activeIndex) + 2,
                                top: 0,
                                bottom: 0,
                                width: tabW - 4,
                                child: const _Lens(),
                              ),
                            Row(
                              children: [
                                for (final item in items.take(half))
                                  Expanded(child: _NavTab(item: item)),
                                const SizedBox(width: _gap),
                                for (final item in items.skip(half))
                                  Expanded(child: _NavTab(item: item)),
                              ],
                            ),
                          ],
                        );
                      }),
                    ),
                  ),
                ),
                Positioned(top: 0, child: _CenterButton(item: center)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The tinted glass under the active tab.
class _Lens extends StatelessWidget {
  const _Lens();

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.red;
    final dark = AppTheme.instance.isDark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(19),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: dark ? 0.22 : 0.14),
            accent.withValues(alpha: dark ? 0.08 : 0.05),
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: dark ? 0.32 : 0.22)),
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          width: 18,
          height: 3,
          margin: const EdgeInsets.only(bottom: 3),
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(3),
            boxShadow: [
              BoxShadow(color: accent.withValues(alpha: 0.7), blurRadius: 8),
            ],
          ),
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
        borderRadius: BorderRadius.circular(19),
        splashColor: AppColors.red.withValues(alpha: 0.12),
        highlightColor: Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSlide(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              offset: Offset(0, item.active ? -0.06 : 0),
              child: AnimatedScale(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                scale: item.active ? 1.08 : 1,
                child: ArcIconView(item.icon,
                    size: 23, color: color, active: item.active),
              ),
            ),
            const SizedBox(height: 3),
            ExcludeSemantics(
              child: Text(
                item.tooltip,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(
                    size: 10.5,
                    weight: item.active ? FontWeight.w700 : FontWeight.w500,
                    color: color),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

class _CenterButton extends StatefulWidget {
  final BottomNavItem item;
  const _CenterButton({required this.item});

  @override
  State<_CenterButton> createState() => _CenterButtonState();
}

class _CenterButtonState extends State<_CenterButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.item.tooltip,
      child: Tooltip(
        message: widget.item.tooltip,
        child: GestureDetector(
          onTap: widget.item.onTap,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          child: AnimatedScale(
            scale: _down ? 0.92 : 1,
            duration: const Duration(milliseconds: 140),
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(21),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFF2B544), Color(0xFFE8622C), Color(0xFFB8461A)],
                  stops: [0, 0.5, 1],
                ),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35), width: 1.2),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFE8622C).withValues(alpha: 0.45),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Center(
                child: ArcIconView(widget.item.icon,
                    size: 28, color: Colors.white, active: true, stroke: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
