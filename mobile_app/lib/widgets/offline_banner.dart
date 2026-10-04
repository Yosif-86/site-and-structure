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
        builder: (context, online, _) => AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          top: online ? -80 : 0,
          left: 0,
          right: 0,
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
    ]);
  }
}
