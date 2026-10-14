import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/net_status.dart';
import '../theme.dart';

/// Thin strip under the status bar while the device has no internet.
/// Slides away by itself once the connection is back.
class OfflineBanner extends StatelessWidget {
  final Widget child;
  const OfflineBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      child,
      ValueListenableBuilder<bool>(
        valueListenable: NetStatus.instance.online,
        // Slide by the bar's own height: a fixed -80 left the bottom edge
        // showing on iPhones whose top safe area is taller than that.
        builder: (context, online, _) => Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            offset: online ? const Offset(0, -1.5) : Offset.zero,
            child: IgnorePointer(
              child: Material(
                color: AppColors.red,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Text(
                      AppStrings.instance.t('offline_banner'),
                      textAlign: TextAlign.center,
                      textDirection: TextDirection.rtl,
                      style: AppFonts.body(size: 12.5, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
