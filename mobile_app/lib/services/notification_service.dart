import 'dart:async';

import 'package:flutter/foundation.dart';

import 'supabase_service.dart';

class AppNotification {
  final String id;
  final String type;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final bool read;

  AppNotification.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        type = j['type'] as String? ?? '',
        title = j['title'] as String? ?? '',
        body = j['body'] as String? ?? '',
        data = (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
        createdAt =
            DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
        read = j['read_at'] != null;
}

/// The signed-in user's notifications, live: a Supabase realtime stream on
/// their own rows (written by database triggers), so the bell's unread
/// count updates the moment something happens, Instagram-style.
class NotificationService extends ChangeNotifier {
  NotificationService._() {
    SupabaseService.instance.addListener(_onAuth);
    _onAuth();
  }
  static final NotificationService instance = NotificationService._();

  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  String? _userId;
  List<AppNotification> _items = const [];

  List<AppNotification> get items => _items;
  int get unread => _items.where((n) => !n.read).length;

  void _onAuth() {
    final uid = SupabaseService.instance.currentUser?.id;
    if (uid == _userId) return;
    _userId = uid;
    _sub?.cancel();
    _sub = null;
    _items = const [];
    notifyListeners();
    if (uid == null) return;
    _sub = SupabaseService.instance.client
        .from('notifications')
        .stream(primaryKey: ['id'])
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(100)
        .listen((rows) {
      _items = rows.map(AppNotification.fromJson).toList();
      notifyListeners();
    }, onError: (_) {
      // Table missing (migration not run yet) or offline: the bell just
      // stays empty rather than erroring.
    });
  }

  Future<void> markRead(String id) async {
    _items = [
      for (final n in _items)
        if (n.id == id)
          AppNotification.fromJson({
            'id': n.id,
            'type': n.type,
            'title': n.title,
            'body': n.body,
            'data': n.data,
            'created_at': n.createdAt.toIso8601String(),
            'read_at': DateTime.now().toIso8601String(),
          })
        else
          n
    ];
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
    try {
      await SupabaseService.instance.client
          .from('notifications')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('user_id', uid)
          .isFilter('read_at', null);
    } catch (_) {}
  }
}
