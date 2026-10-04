import 'package:flutter/material.dart';

import '../theme.dart';
import 'arc_icons.dart';
import 'arc_mark.dart';
import 'glass_card.dart';

/// Building blocks shared by the admin and teacher dashboards, in the same
/// blueprint language as the student app: glass cards, Arc icons in tinted
/// squircles, orange-tick section labels, colour-coded status pills.

/// Top-of-dashboard hero: today's date, title, one-line summary, a row of
/// headline numbers, and the mark as a faint watermark.
class DashHero extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<(String value, String label)> stats;
  /// Optional tap per stat (same order as [stats]); null = not tappable.
  final List<VoidCallback?> statTaps;

  const DashHero(
      {super.key,
      required this.title,
      required this.subtitle,
      this.stats = const [],
      this.statTaps = const []});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final date =
        '${now.year}/${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}';
    final dark = AppTheme.instance.isDark;
    return GlassCard(
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(22),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: AlignmentDirectional.topEnd.resolve(Directionality.of(context)),
                  radius: 1.2,
                  colors: [
                    AppColors.red.withValues(alpha: dark ? 0.20 : 0.10),
                    AppColors.red.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          PositionedDirectional(
            end: -18,
            bottom: -26,
            child: Opacity(
              opacity: dark ? 0.08 : 0.07,
              child: ArcMark(size: 150, color: AppColors.red),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  ArcIconView(ArcIcon.calendar,
                      size: 14, color: AppColors.muted2),
                  const SizedBox(width: 6),
                  Text(date, style: AppFonts.code(size: 11.5, color: AppColors.muted2)),
                ]),
                const SizedBox(height: 10),
                Text(title, style: AppFonts.body(size: 24, weight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: AppFonts.body(size: 13, color: AppColors.muted)),
                if (stats.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  IntrinsicHeight(
                    child: Row(
                      children: [
                        for (var i = 0; i < stats.length; i++) ...[
                          if (i > 0)
                            VerticalDivider(
                                width: 24, thickness: 1, color: AppColors.line),
                          Expanded(
                            child: InkWell(
                              onTap: i < statTaps.length ? statTaps[i] : null,
                              borderRadius: BorderRadius.circular(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: AlignmentDirectional.centerStart,
                                    child: Text(stats[i].$1,
                                        style: AppFonts.heading(
                                            size: 26, color: AppColors.text)),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(children: [
                                    Flexible(
                                      child: Text(stats[i].$2,
                                          maxLines: 2,
                                          style: AppFonts.body(
                                              size: 11.5,
                                              color: AppColors.muted)),
                                    ),
                                    if (i < statTaps.length &&
                                        statTaps[i] != null) ...[
                                      const SizedBox(width: 4),
                                      ArcIconView(ArcIcon.chevron,
                                          size: 12, color: AppColors.muted2),
                                    ],
                                  ]),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "▍ Title" label above a group of cards.
class DashSection extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const DashSection(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 10),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFF2B544), Color(0xFFE8622C)],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title,
                style: AppFonts.body(size: 16, weight: FontWeight.w700)),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Responsive grid: two columns on phones, more as the screen widens.
class DashGrid extends StatelessWidget {
  final List<Widget> children;
  final double minTileWidth;
  final double tileHeight;
  const DashGrid(
      {super.key,
      required this.children,
      this.minTileWidth = 165,
      this.tileHeight = 142});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / minTileWidth).floor().clamp(2, 5);
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: tileHeight,
        ),
        itemCount: children.length,
        itemBuilder: (context, i) => children[i],
      );
    });
  }
}

/// Tinted squircle holding an Arc icon.
class DashIconBadge extends StatelessWidget {
  final ArcIcon icon;
  final Color accent;
  final double size;
  const DashIconBadge(
      {super.key, required this.icon, required this.accent, this.size = 42});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.26),
            accent.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Center(
          child: ArcIconView(icon,
              color: accent, size: size * 0.52, active: true)),
    );
  }
}

/// Initials in a gradient ring, for people lists.
class DashAvatar extends StatelessWidget {
  final String? name;
  final double size;
  const DashAvatar({super.key, required this.name, this.size = 42});

  @override
  Widget build(BuildContext context) {
    final n = (name ?? '').trim();
    final initial = n.isEmpty || n == '—' ? null : n.characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(1.6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [AppColors.red, AppColors.teal],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: ClipOval(
        child: ColoredBox(
          color: AppColors.panel2,
          child: Center(
            child: initial != null
                ? Text(initial,
                    style: AppFonts.body(size: size * 0.38, weight: FontWeight.w700))
                : ArcIconView(ArcIcon.profile,
                    size: size * 0.5, color: AppColors.muted),
          ),
        ),
      ),
    );
  }
}

/// Dashboard tile: icon, big number, label. [alert] adds a pulsing-orange
/// dot when the number is something waiting on the admin.
class DashStatCard extends StatelessWidget {
  final ArcIcon icon;
  final String value;
  final String label;
  final Color accent;
  final VoidCallback onTap;
  final bool alert;

  const DashStatCard({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    required this.accent,
    required this.onTap,
    this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      borderRadius: BorderRadius.circular(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DashIconBadge(icon: icon, accent: accent, size: 40),
              const Spacer(),
              if (alert)
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFF2B544),
                    boxShadow: [
                      BoxShadow(
                          color: const Color(0xFFF2B544).withValues(alpha: 0.7),
                          blurRadius: 8),
                    ],
                  ),
                )
              else
                ArcIconView(ArcIcon.chevron, size: 16, color: AppColors.muted2),
            ],
          ),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(value, style: AppFonts.heading(size: 28)),
          ),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.body(size: 12, color: AppColors.muted, weight: FontWeight.w500)),
        ],
      ),
    );
  }
}

enum StatusTone { good, warn, bad, neutral }

class StatusPill extends StatelessWidget {
  final String label;
  final StatusTone tone;
  const StatusPill(this.label, {super.key, this.tone = StatusTone.neutral});

  @override
  Widget build(BuildContext context) {
    final c = switch (tone) {
      StatusTone.good => AppColors.teal,
      StatusTone.warn => const Color(0xFFE0A030),
      StatusTone.bad => AppColors.error,
      StatusTone.neutral => AppColors.muted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        border: Border.all(color: c.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
          const SizedBox(width: 6),
          Text(label,
              style: AppFonts.body(size: 11, weight: FontWeight.w600, color: c)),
        ],
      ),
    );
  }
}

/// A list row: leading badge/avatar, title, subtitle, small meta lines,
/// an optional status pill and a row of actions.
class DashCard extends StatelessWidget {
  final Widget? leading;
  final String title;
  final TextStyle? titleStyle;
  final String? subtitle;
  final List<String> meta;
  final Color? metaColor;
  final Widget? trailing;
  final List<Widget> actions;
  final List<Widget> extra;
  final VoidCallback? onTap;

  const DashCard({
    super.key,
    this.leading,
    required this.title,
    this.titleStyle,
    this.subtitle,
    this.meta = const [],
    this.metaColor,
    this.trailing,
    this.actions = const [],
    this.extra = const [],
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      borderRadius: BorderRadius.circular(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle ??
                            AppFonts.body(size: 15, weight: FontWeight.w700)),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(subtitle!,
                          style: AppFonts.body(size: 12.5, color: AppColors.muted)),
                    ],
                    for (final m in meta) ...[
                      const SizedBox(height: 3),
                      Text(m,
                          style: AppFonts.body(
                              size: 11.5, color: metaColor ?? AppColors.muted2)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
          ...extra,
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}

/// Compact action button for cards: primary (orange), danger, or quiet.
class DashButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final ArcIcon? icon;
  final bool primary;
  final bool danger;

  const DashButton(this.label,
      {super.key,
      required this.onPressed,
      this.icon,
      this.primary = false,
      this.danger = false});

  @override
  Widget build(BuildContext context) {
    final fg = primary
        ? Colors.white
        : (danger ? AppColors.error : AppColors.text);
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          ArcIconView(icon!, size: 16, color: fg),
          const SizedBox(width: 6),
        ],
        Text(label),
      ],
    );
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    const size = Size(0, 38);
    const pad = EdgeInsets.symmetric(horizontal: 14);
    return primary
        ? ElevatedButton(
            onPressed: onPressed,
            style: ElevatedButton.styleFrom(
                minimumSize: size, padding: pad, shape: shape),
            child: child)
        : OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              minimumSize: size,
              padding: pad,
              shape: shape,
              foregroundColor: fg,
              side: BorderSide(
                  color: danger
                      ? AppColors.error.withValues(alpha: 0.5)
                      : AppColors.line),
            ),
            child: child);
  }
}

/// Centered empty state with an icon.
class DashEmpty extends StatelessWidget {
  final ArcIcon icon;
  final String message;
  const DashEmpty({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.glassBg,
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Center(
                child: ArcIconView(icon,
                    size: 32, color: AppColors.muted, active: true)),
          ),
          const SizedBox(height: 14),
          Text(message,
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 14, color: AppColors.muted)),
        ],
      ),
    );
  }
}

/// Glass panel wrapping a form, with a titled header.
class DashFormPanel extends StatelessWidget {
  final String title;
  final ArcIcon icon;
  final List<Widget> children;
  const DashFormPanel(
      {super.key, required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            DashIconBadge(icon: icon, accent: AppColors.red, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title,
                  style: AppFonts.body(size: 16, weight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }
}
