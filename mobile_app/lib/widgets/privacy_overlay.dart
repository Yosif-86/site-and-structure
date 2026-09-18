import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Wraps the whole app. Shows a full-screen brand cover whenever the app is
/// backgrounded/inactive, so the OS app-switcher thumbnail never shows real
/// content — the app-wide half of the screenshot/recording privacy story
/// (the video-screen-specific half lives in video_player_screen.dart).
class PrivacyOverlay extends StatefulWidget {
  final Widget child;
  const PrivacyOverlay({super.key, required this.child});

  @override
  State<PrivacyOverlay> createState() => _PrivacyOverlayState();
}

class _PrivacyOverlayState extends State<PrivacyOverlay>
    with WidgetsBindingObserver {
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // iOS takes its app-switcher snapshot while the app is still `inactive`,
  // so that's when the cover has to be up. On Android `inactive` also fires
  // for the image picker, permission prompts, and the notification shade,
  // where covering the app mid-flow (e.g. while picking a payment
  // screenshot) is wrong -- there the switcher thumbnail comes from
  // `paused`, so only cover from that point on.
  bool _shouldCover(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return false;
    if (state == AppLifecycleState.inactive) return !kIsWeb && Platform.isIOS;
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final shouldCover = _shouldCover(state);
    if (shouldCover != _covered) {
      setState(() => _covered = shouldCover);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_covered)
          Positioned.fill(
            child: Container(
              color: const Color(0xFF14120F),
              child: Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFE8622C), Color(0xFF8A3A1B)],
                    ),
                  ),
                  child: const Icon(Icons.change_history,
                      color: Colors.white, size: 28),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
