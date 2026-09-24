import 'package:flutter/material.dart';

import '../theme.dart';
import 'ambient_background.dart';

/// Scaffold for every glass-themed screen: the ambient backdrop runs the
/// full height of the screen -- under a transparent app bar and under any
/// floating bottom bar -- so the colour washes never get cut off in a hard
/// line at the header, and glass surfaces always have something to blur.
///
/// The body is wrapped in a top-only SafeArea. With extendBodyBehindAppBar,
/// Scaffold already folds the app bar's height into the body's top padding,
/// so this lands content just below the header (or the status bar, when
/// there's no app bar). SafeArea also consumes that padding, so any inner
/// SafeArea a screen still has becomes a harmless no-op instead of doubling
/// the gap.
class GlassScaffold extends StatelessWidget {
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? bottomNavigationBar;
  final bool resizeToAvoidBottomInset;

  const GlassScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.bottomNavigationBar,
    this.resizeToAvoidBottomInset = true,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      backgroundColor: AppColors.bg,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      appBar: appBar,
      bottomNavigationBar: bottomNavigationBar,
      body: AmbientBackground(
        child: SafeArea(bottom: false, child: body),
      ),
    );
  }
}
