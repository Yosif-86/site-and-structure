import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'supabase_service.dart';

// Runs in the background isolate. Firebase already shows the notification
// itself when the app is in the background or closed; nothing else to do.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {}

/// Phone (lock-screen) notifications. Each signed-in phone registers its
/// Firebase token (register_push_token); the database sends every new bell
/// notification to it through api/push.js. While the app is open the same
/// message is shown as a local notification, since Firebase doesn't show
/// one in the foreground.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  static const _channel = AndroidNotificationChannel(
    'arc_default',
    'إشعارات آرك',
    description: 'الدفعات والمحاضرات والتنبيهات المهمة',
    importance: Importance.high,
  );

  final _local = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  String? _registeredFor;
  String? _token;

  /// Set by the app: opens the notifications screen when one is tapped.
  void Function()? onOpen;

  Future<void> init() async {
    if (kIsWeb || _ready) return;
    try {
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint('push: Firebase init failed: $e');
      return;
    }
    _ready = true;
    FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);
    // iPhone shows the banner itself while the app is open, so no local
    // copy is needed there (see _showForeground).
    if (Platform.isIOS) {
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
              alert: true, badge: true, sound: true);
    }

    await _local.initialize(
      const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_arc'),
          // Permission is asked by Firebase in _onAuth, not here.
          iOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestBadgePermission: false,
              requestSoundPermission: false)),
      onDidReceiveNotificationResponse: (_) => onOpen?.call(),
    );
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    FirebaseMessaging.onMessage.listen(_showForeground);
    FirebaseMessaging.onMessageOpenedApp.listen((_) => onOpen?.call());
    // Opened from a notification while the app was closed.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(seconds: 2), () => onOpen?.call());
      });
    }
    FirebaseMessaging.instance.onTokenRefresh.listen((t) {
      _token = t;
      _registeredFor = null;
      _onAuth();
    });
    SupabaseService.instance.addListener(_onAuth);
    _onAuth();
  }

  Future<void> _onAuth() async {
    final uid = SupabaseService.instance.currentUser?.id;
    if (!_ready || uid == null || uid == _registeredFor) return;
    _registeredFor = uid;
    try {
      // Android 13+ asks the user once.
      await FirebaseMessaging.instance.requestPermission();
      // On iPhone Firebase has no token until Apple's push token arrives,
      // which can take a few seconds after permission is granted.
      if (Platform.isIOS) {
        for (var i = 0;
            i < 10 && await FirebaseMessaging.instance.getAPNSToken() == null;
            i++) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
      _token ??= await FirebaseMessaging.instance.getToken();
      final token = _token;
      if (token == null) {
        _registeredFor = null;
        return;
      }
      await SupabaseService.instance.client.rpc('register_push_token', params: {
        'p_token': token,
        'p_platform': Platform.isIOS ? 'ios' : 'android',
      });
    } catch (e) {
      // Offline or the push table not added yet: retried on next sign-in.
      _registeredFor = null;
      debugPrint('push: register failed: $e');
    }
  }

  /// Called before signing out, so this phone stops getting that account's
  /// notifications.
  Future<void> unregister() async {
    final token = _token;
    _registeredFor = null;
    if (!_ready || token == null) return;
    try {
      await SupabaseService.instance.client
          .from('push_tokens')
          .delete()
          .eq('token', token)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<void> _showForeground(RemoteMessage m) async {
    final n = m.notification;
    if (n == null || Platform.isIOS) return;
    await _local.show(
      m.hashCode,
      n.title,
      n.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_stat_arc',
          // Same coloured picture as the phone icon, beside the text (the
          // small icon above must be a one-colour silhouette on Android).
          largeIcon: const DrawableResourceAndroidBitmap('ic_notification_large'),
          color: const Color(0xFFE8622C),
        ),
      ),
    );
  }
}
