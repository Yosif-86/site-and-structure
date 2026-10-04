import 'dart:async';

import 'package:flutter/widgets.dart';

import 'net_status.dart';
import 'supabase_service.dart';

class AppNotification {
  final String id;
  final String type;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final bool read;

  AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.data,
    required this.createdAt,
    required this.read,
  });

  /// Lenient: one odd row must never blank the whole list.
  static AppNotification? tryParse(Map<String, dynamic> j) {
    try {
      final id = j['id']?.toString();
      if (id == null) return null;
      final raw = j['data'];
      return AppNotification(
        id: id,
        type: j['type']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        body: j['body']?.toString() ?? '',
        data: raw is Map ? raw.cast<String, dynamic>() : const {},
        createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '') ??
            DateTime.now(),
        read: j['read_at'] != null,
      );
    } catch (_) {
      return null;
    }
  }

  AppNotification markedRead() => AppNotification(
      id: id,
      type: type,
      title: title,
      body: body,
      data: data,
      createdAt: createdAt,
      read: true);
}

/// The signed-in user's notifications, live: a Supabase realtime stream on
/// their own rows (written by database triggers), so the bell's unread
/// count updates the moment something happens.
///
/// The stream closes for good if its first fetch fails (opened offline, token
/// refreshing, ...), which used to leave the bell empty for the whole
/// session. It now reconnects: after an error, when the app comes back to
/// the foreground, and when the internet returns.
class NotificationService extends ChangeNotifier with WidgetsBindingObserver {
  NotificationService._() {
    SupabaseService.instance.addListener(_onAuth);
    WidgetsBinding.instance.addObserver(this);
    NetStatus.instance.online.addListener(_onNet);
    _onAuth();
  }
  static final NotificationService instance = NotificationService._();

  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  Timer? _retry;
  int _failures = 0;
  String? _userId;
  List<AppNotification> _items = const [];

  List<AppNotification> get items => _items;
  int get unread => _items.where((n) => !n.read).length;

  void _onAuth() {
    final uid = SupabaseService.instance.currentUser?.id;
    if (uid == _userId) return;
    _userId = uid;
    _items = const [];
    notifyListeners();
    _subscribe();
  }

  void _onNet() {
    if (NetStatus.instance.online.value && _userId != null) _subscribe();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _userId != null) _subscribe();
  }

  /// Restarts the live stream (also used by pull-to-refresh).
  Future<void> refresh() async => _subscribe();

  void _subscribe() {
    _retry?.cancel();
    _retry = null;
    _sub?.cancel();
    _sub = null;
    final uid = _userId;
    if (uid == null) return;
    _sub = SupabaseService.instance.client
        .from('notifications')
        .stream(primaryKey: ['id'])
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(100)
        .listen((rows) {
      _failures = 0;
      _items = rows
          .map(AppNotification.tryParse)
          .whereType<AppNotification>()
          .toList();
      notifyListeners();
    }, onError: (_) => _scheduleRetry(), onDone: _scheduleRetry);
  }

  void _scheduleRetry() {
    if (_userId == null || _retry != null) return;
    _failures++;
    final seconds = _failures < 3 ? 5 : (_failures < 6 ? 15 : 60);
    _retry = Timer(Duration(seconds: seconds), () {
      _retry = null;
      _subscribe();
    });
  }

  Future<void> markRead(String id) async {
    _items = [for (final n in _items) n.id == id ? n.markedRead() : n];
    notifyListeners();
    try {
      await SupabaseService.instance.client
          .from('notifications')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', id);
    } catch (_) {}
  }

  Future<void> markAllRead() async {
    final uid = _userId;
    if (uid == null || unread == 0) return;
    // Clear the badge right away instead of waiting for the realtime echo.
    _items = [for (final n in _items) n.read ? n : n.markedRead()];
    notifyListeners();
    try {
      await SupabaseService.instance.client
          .from('notifications')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('user_id', uid)
          .isFilter('read_at', null);
    } catch (_) {}
  }
}
