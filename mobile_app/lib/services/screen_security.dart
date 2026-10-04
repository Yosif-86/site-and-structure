import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'supabase_service.dart';

/// Talks to the native code in MainActivity.kt (Android) and AppDelegate.swift
/// (iOS) — replaces the screen_protector package, which failed to build
/// against current Android tooling.
///
/// Android/iOS only. There is no browser API to block or reliably detect
/// screen capture, so this is a no-op on web — the app must never be built
/// for `flutter build web`/Flutter Web for the video screens, since none of
/// this protection exists there. `kIsWeb` is checked before any `dart:io
/// Platform` call because `Platform.isAndroid` throws on web.
///
/// Android: `enableSecure`/`disableSecure` below are now no-ops — MainActivity
/// sets FLAG_SECURE once, app-wide, for the whole session instead of toggling
/// it per-screen (toggling it off outside the video screen was what let the
/// recents/task-switcher thumbnail show real content — see MainActivity.kt's
/// doc comment for why). Left in place, and still called from
/// video_player_screen.dart, purely so a future per-screen need on iOS (which
/// has no FLAG_SECURE equivalent) doesn't require touching those call sites.
///
/// FLAG_SECURE only covers video — a screen recording's audio track is a
/// separate Android API (AudioPlaybackCapture) that FLAG_SECURE doesn't
/// touch, so it's blocked app-wide instead via
/// android:allowAudioPlaybackCapture="false" in AndroidManifest.xml.
class ScreenSecurity {
  static const _channel = MethodChannel('site_and_structure/screen_security');
  static void Function(String type)? _onCapture;

  static bool _handlerSet = false;

  /// What the user is looking at, for the admin's report (set by screens
  /// like the video player).
  static String? currentScreen;
  static DateTime? _lastReport;

  /// Call once at start-up so capture attempts are reported app-wide.
  static void init() => _ensureHandler();

  static void _ensureHandler() {
    if (kIsWeb || _handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCapture') {
        final type = (call.arguments as Map)['type'] as String? ?? 'unknown';
        _report(type);
        _onCapture?.call(type);
      }
      return null;
    });
  }

  /// Logs the attempt as a security event (the database notifies the
  /// admins). At most one report every 30 seconds.
  static Future<void> _report(String type) async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;
    final now = DateTime.now();
    if (_lastReport != null && now.difference(_lastReport!).inSeconds < 30) {
      return;
    }
    _lastReport = now;
    try {
      await SupabaseService.instance.client.from('security_events').insert({
        'user_id': user.id,
        'kind': type == 'recording' ? 'screen_record' : 'screenshot',
        'detail': {'screen': currentScreen ?? 'app'},
      });
    } catch (_) {
      // Table not there yet, or offline: never disturb the user over this.
    }
  }

  /// Android: turns FLAG_SECURE on, blocking screenshots/recording outright.
  /// iOS: no-op (there is no equivalent — see [onCapture]). Web: no-op.
  static Future<void> enableSecure() async {
    if (!kIsWeb && Platform.isAndroid) {
      await _channel.invokeMethod('setSecure', {'secure': true});
    }
  }

  static Future<void> disableSecure() async {
    if (!kIsWeb && Platform.isAndroid) {
      await _channel.invokeMethod('setSecure', {'secure': false});
    }
  }

  /// Fires with 'screenshot' or 'recording' when a capture is detected
  /// (iOS always; Android 14+ screenshots, Android 15+ recording). Set to
  /// null to stop listening.
  static void onCapture(void Function(String type)? callback) {
    _ensureHandler();
    _onCapture = callback;
  }
}
