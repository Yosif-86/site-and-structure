import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../theme.dart';
import 'glass_card.dart';

class CourseCard extends StatelessWidget {
  final Course course;
  final VoidCallback onTap;
  const CourseCard({super.key, required this.course, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    final t = AppStrings.instance.t;
    final title = course.localizedTitle(ar);
    final desc = course.localizedDescription(ar);
    final teacher = course.localizedTeacherName(ar);
    final tag = course.localizedTagLabel(ar);

    return GlassCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (course.thumbnailUrl != null)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                course.thumbnailUrl!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    ColoredBox(color: AppColors.panel2),
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : ColoredBox(color: AppColors.panel2),
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tag != null && tag.isNotEmpty) ...[
                    _Tag(
                        label: tag,
                        color: course.tagColor == 'green'
                            ? AppColors.teal
                            : AppColors.red),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    title,
                    style: AppFonts.body(size: 16, weight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (teacher != null && teacher.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(teacher,
                        style: AppFonts.body(size: 13, color: AppColors.muted)),
                  ],
                  if (desc != null && desc.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      desc,
                      style: AppFonts.body(size: 13, color: AppColors.muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const Spacer(),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      course.isFree
                          ? Text(t('card_free'),
                              style: AppFonts.body(
                                  size: 15,
                                  weight: FontWeight.w700,
                                  color: AppColors.teal))
                          : Text(course.price ?? '',
                              style: AppFonts.code(
                                  size: 15,
                                  weight: FontWeight.w700,
                                  color: AppColors.red)),
                      Icon(
                          ar
                              ? Icons.arrow_back_ios_new
                              : Icons.arrow_forward_ios,
                          size: 14,
                          color: AppColors.muted2),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Large hero card for the first course on Home: thumbnail with a bottom
/// gradient, title and teacher on the image, price pill in the corner.
class FeaturedCourseCard extends StatelessWidget {
  final Course course;
  final VoidCallback onTap;
  const FeaturedCourseCard(
      {super.key, required this.course, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    final t = AppStrings.instance.t;
    final title = course.localizedTitle(ar);
    final teacher = course.localizedTeacherName(ar);
    final tag = course.localizedTagLabel(ar);

    return GlassCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (course.thumbnailUrl != null)
              Image.network(
                course.thumbnailUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    ColoredBox(color: AppColors.panel2),
                loadingBuilder: (_, child, p) =>
                    p == null ? child : ColoredBox(color: AppColors.panel2),
              )
            else
              ColoredBox(color: AppColors.panel2),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.35, 1],
                  colors: [Colors.transparent, Color(0xE6120F0C)],
                ),
              ),
            ),
            PositionedDirectional(
              top: 12,
              start: 12,
              child: _PricePill(course: course, t: t),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tag != null && tag.isNotEmpty) ...[
                    Text(tag,
                        style: AppFonts.eyebrow(
                            color:
                                const Color(0xFFF3EDE4).withValues(alpha: 0.8),
                            size: 11)),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    title,
                    style: AppFonts.body(
                        size: 20,
                        weight: FontWeight.w700,
                        color: const Color(0xFFF3EDE4)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (teacher != null && teacher.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(teacher,
                        style: AppFonts.body(
                            size: 13,
                            color: const Color(0xFFF3EDE4)
                                .withValues(alpha: 0.75))),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact list row for Home: thumbnail on the side, title, teacher, price.
class CompactCourseCard extends StatelessWidget {
  final Course course;
  final VoidCallback onTap;
  const CompactCourseCard(
      {super.key, required this.course, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    final t = AppStrings.instance.t;
    final title = course.localizedTitle(ar);
    final teacher = course.localizedTeacherName(ar);

    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 104,
              height: 74,
              child: course.thumbnailUrl != null
                  ? Image.network(
                      course.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          ColoredBox(color: AppColors.panel2),
                      loadingBuilder: (_, child, p) => p == null
                          ? child
                          : ColoredBox(color: AppColors.panel2),
                    )
                  : ColoredBox(
                      color: AppColors.panel2,
                      child: Icon(Icons.play_circle_outline,
                          color: AppColors.muted2),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: AppFonts.body(size: 15, weight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (teacher != null && teacher.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(teacher,
                      style: AppFonts.body(size: 12.5, color: AppColors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 6),
                course.isFree
                    ? Text(t('card_free'),
                        style: AppFonts.body(
                            size: 13,
                            weight: FontWeight.w700,
                            color: AppColors.teal))
                    : Text(course.price ?? '',
                        style: AppFonts.code(
                            size: 13,
                            weight: FontWeight.w700,
                            color: AppColors.red)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(ar ? Icons.chevron_left : Icons.chevron_right,
              color: AppColors.muted2),
        ],
      ),
    );
  }
}

class _PricePill extends StatelessWidget {
  final Course course;
  final String Function(String) t;
  const _PricePill({required this.course, required this.t});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF14120F).withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
        border:
            Border.all(color: const Color(0xFFF3EDE4).withValues(alpha: 0.18)),
      ),
      child: course.isFree
          ? Text(t('card_free'),
              style: AppFonts.body(
                  size: 12.5, weight: FontWeight.w700, color: AppColors.teal))
          : Text(course.price ?? '',
              style: AppFonts.code(
                  size: 12.5,
                  weight: FontWeight.w700,
                  color: const Color(0xFFF3EDE4))),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: AppFonts.eyebrow(color: color, size: 10.5)),
    );
  }
}
