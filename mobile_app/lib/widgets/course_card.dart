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
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tag != null && tag.isNotEmpty)
            Text(tag.toUpperCase(), style: AppFonts.eyebrow(color: course.tagColor == 'green' ? AppColors.teal : AppColors.red)),
          const SizedBox(height: 8),
          Text(
            title,
            style: AppFonts.body(size: 17, weight: FontWeight.w600),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (teacher != null && teacher.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('${t('card_by')} $teacher', style: AppFonts.mono(size: 11, color: AppColors.byline, letterSpacing: 0.3)),
          ],
          if (desc != null && desc.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(desc, style: AppFonts.body(size: 13.5, color: AppColors.muted), maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
          const Spacer(),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              course.isFree
                  ? Text(t('card_free'), style: AppFonts.heading(size: 20, color: AppColors.teal))
                  : Text(course.price ?? '', style: AppFonts.heading(size: 20, color: AppColors.red)),
              Icon(ar ? Icons.arrow_back_ios : Icons.arrow_forward_ios, size: 14, color: AppColors.muted2),
            ],
          ),
        ],
      ),
    );
  }
}
