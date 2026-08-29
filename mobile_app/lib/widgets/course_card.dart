import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../theme.dart';

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

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (tag != null && tag.isNotEmpty)
                Text(
                  tag.toUpperCase(),
                  style: TextStyle(
                    color: course.tagColor == 'green' ? AppColors.teal : AppColors.red,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                title,
                style: const TextStyle(color: AppColors.text, fontSize: 17, fontWeight: FontWeight.w700),
              ),
              if (teacher != null && teacher.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('${t('card_by')} $teacher',
                    style: const TextStyle(color: Color(0xFFA8496B), fontSize: 12)),
              ],
              if (desc != null && desc.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(desc, style: const TextStyle(color: AppColors.muted, fontSize: 13.5), maxLines: 3, overflow: TextOverflow.ellipsis),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  course.isFree
                      ? Text(t('card_free'), style: const TextStyle(color: AppColors.teal, fontSize: 20, fontWeight: FontWeight.w800))
                      : Text(course.price ?? '', style: const TextStyle(color: AppColors.red, fontSize: 20, fontWeight: FontWeight.w800)),
                  Icon(ar ? Icons.arrow_back_ios : Icons.arrow_forward_ios, size: 14, color: AppColors.muted2),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
