import 'package:flutter/material.dart';

import '../theme.dart';
import 'arc_mark.dart';

/// The app header's brand: the official ARC Platform lockup (brand sheet
/// V5). Dark mode uses the primary colors (orange mark, cream text); light
/// mode uses the monochrome dark version (#5). Listens to the theme itself
/// because it's built as a const widget and wouldn't otherwise repaint
/// when the theme is toggled.
class BrandTitle extends StatelessWidget {
  const BrandTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppTheme.instance,
      builder: (context, _) => AppTheme.instance.isDark
          ? const ArcLogo(height: 40)
          : const ArcLogo.dark(height: 40),
    );
  }
}
