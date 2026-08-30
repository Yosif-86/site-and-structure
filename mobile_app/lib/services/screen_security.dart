import 'dart:io';

import 'package:flutter/services.dart';

/// Talks to the native code in MainActivity.kt (Android) and AppDelegate.swift
/// (iOS) — replaces the screen_protector package, which failed to build
/// against current Android tooling.
class ScreenSecurity {
  static const _channel = MethodChannel('site_and_structure/screen_security');
  static void Function(String type)? _onCapture;

  static bool _handlerSet = false;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCapture') {
        final type = (call.arguments as Map)['type'] as String? ?? 'unknown';
        _onCapture?.call(type);
      }
      return null;
    });
  }

  /// Android: turns FLAG_SECURE on, blocking screenshots/recording outright.
  /// iOS: no-op (there is no equivalent — see [onCapture]).
  static Future<void> enableSecure() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('setSecure', {'secure': true});
    }
  }

  static Future<void> disableSecure() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('setSecure', {'secure': false});
    }
  }

  /// iOS only: fires with 'screenshot' or 'recording' whenever a capture is
  /// detected. Set to null to stop listening.
  static void onCapture(void Function(String type)? callback) {
    _ensureHandler();
    _onCapture = callback;
  }
}
