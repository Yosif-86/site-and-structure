import 'package:flutter/material.dart';

import '../theme.dart';

/// On a tablet the app stays a centred column instead of stretching every
/// screen across 1000+ px; the sides use the theme's background. The video
/// player asks for the full width while it is open.
class TabletFrame extends StatelessWidget {
  final Widget child;
  const TabletFrame({super.key, required this.child});

  static const double maxContentWidth = 720;

  /// Screens that need the whole width (the video player) raise this while
  /// they are open.
  static final ValueNotifier<int> fullBleed = ValueNotifier<int>(0);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: fullBleed,
      builder: (context, bleed, _) {
        final width = MediaQuery.sizeOf(context).width;
        if (bleed > 0 || width <= maxContentWidth) return child;
        return ColoredBox(
          color: AppColors.bg,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: maxContentWidth),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
