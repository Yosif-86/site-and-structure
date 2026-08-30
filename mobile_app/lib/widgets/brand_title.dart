import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../theme.dart';

/// Port of the website's `.brand` — gradient mark + wordmark, used as the
/// catalogue screen's AppBar title.
class BrandTitle extends StatelessWidget {
  const BrandTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.red, Color(0xFF7A3113)],
            ),
          ),
          alignment: Alignment.center,
          child: Text('S&S', style: AppFonts.mono(size: 10, color: Colors.white, weight: FontWeight.w700, letterSpacing: 0.5)),
        ),
        const SizedBox(width: 10),
        Text(AppStrings.instance.t('app_name').toUpperCase(), style: AppFonts.heading(size: 17)),
      ],
    );
  }
}
