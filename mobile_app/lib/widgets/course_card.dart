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
