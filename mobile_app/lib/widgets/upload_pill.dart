import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/upload_manager.dart';
import '../theme.dart';

/// Small floating progress pill shown anywhere in the app while a lecture
/// is uploading in the background.
class UploadPill extends StatelessWidget {
  final Widget child;
  const UploadPill({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final mgr = UploadManager.instance;
    return Stack(children: [
      child,
      AnimatedBuilder(
        animation: mgr,
        builder: (context, _) {
          final active =
              mgr.jobs.where((j) => j.status == UploadStatus.uploading).toList();
          if (active.isEmpty) return const SizedBox.shrink();
          final progress = active.fold<double>(0, (s, j) => s + j.progress) /
              active.length;
          final label = active.length == 1
              ? AppStrings.instance
                  .t('upload_pill_one')
                  .replaceAll('{title}', active.first.title)
              : AppStrings.instance
                  .t('upload_pill_many')
                  .replaceAll('{n}', '${active.length}');
          return Positioned(
            left: 16,
            right: 16,
            bottom: 96,
            child: SafeArea(
              child: Center(
                child: Material(
                  color: AppColors.panel,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(24),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      textDirection: TextDirection.rtl,
                      children: [
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 2.6,
                            color: AppColors.teal,
                            backgroundColor:
                                AppColors.muted2.withValues(alpha: 0.25),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            '$label  ${(progress * 100).round()}%',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textDirection: TextDirection.rtl,
                            style: AppFonts.body(size: 12.5, color: AppColors.text),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ]);
  }
}
