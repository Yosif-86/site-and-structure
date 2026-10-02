import 'package:flutter/material.dart';

import '../theme.dart';
import 'arc_mark.dart';

/// The app header's brand: the official ARC Platform lockup (brand sheet
/// V5), text following the theme so it stays readable in light mode.
class BrandTitle extends StatelessWidget {
  const BrandTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return ArcLogo(height: 40, textColor: AppColors.text);
  }
}
