import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Reloads a screen by itself when the data behind it changes, so nobody has
/// to pull down to refresh: a Supabase realtime subscription on the given
/// tables (row-level security still decides which changes this user sees),
/// with bursts collapsed into one reload.
class LiveRefresh {
  final List<String> tables;
  final Future<void> Function() onChange;
  final Duration debounce;

  RealtimeChannel? _channel;
  Timer? _timer;

  LiveRefresh({
    required this.tables,
    required this.onChange,
    this.debounce = const Duration(milliseconds: 700),
  });

  void start() {
    if (_channel != null) return;
    final client = SupabaseService.instance.client;
    final channel = client.channel(
        'live-${tables.join('-')}-${DateTime.now().microsecondsSinceEpoch}');
    for (final table in tables) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => _schedule(),
      );
    }
    _channel = channel..subscribe();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, () => onChange().catchError((_) {}));
  }

  void stop() {
    _timer?.cancel();
    final ch = _channel;
    _channel = null;
    if (ch != null) SupabaseService.instance.client.removeChannel(ch);
  }
}
