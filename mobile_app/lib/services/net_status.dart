import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'supabase_service.dart';

/// App-wide online/offline state. Drives the offline banner and lets screens
/// reload by themselves once the connection is back.
///
/// Connectivity events alone aren't trusted (Wi-Fi can be "connected" with no
/// internet), so every change is confirmed with a small request to Supabase.
/// While offline, that check repeats every few seconds until it succeeds.
class NetStatus {
  NetStatus._();
  static final NetStatus instance = NetStatus._();

  final ValueNotifier<bool> online = ValueNotifier(true);
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _retry;
  bool _probing = false;

  void start() {
    _sub ??= Connectivity().onConnectivityChanged.listen((results) {
      if (results.every((r) => r == ConnectivityResult.none)) {
        _setOnline(false);
      } else {
        _probe();
      }
    });
    _probe();
  }

  /// Called when a request failed with a network error.
  void reportOffline() => _setOnline(false);

  /// True for errors that mean "no internet", not a server or app problem.
  static bool isOffline(Object e) {
    if (e is SocketException || e is TimeoutException) return true;
    if (e is HandshakeException) return true;
    final s = e.toString();
    return s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('Connection refused') ||
        s.contains('Connection reset') ||
        s.contains('Connection closed') ||
        s.contains('Network is unreachable') ||
        s.contains('ClientException') ||
        s.contains('AuthRetryableFetchException');
  }

  void _setOnline(bool value) {
    if (online.value != value) online.value = value;
    if (value) {
      _retry?.cancel();
      _retry = null;
    } else {
      _retry ??= Timer.periodic(const Duration(seconds: 5), (_) => _probe());
    }
  }

  Future<void> _probe() async {
    if (_probing) return;
    _probing = true;
    try {
      final res = await http
          .get(Uri.parse('$kSupabaseUrl/auth/v1/health'),
              headers: {'apikey': kSupabaseAnonKey})
          .timeout(const Duration(seconds: 6));
      // Any HTTP answer means the internet works.
      _setOnline(res.statusCode > 0);
    } catch (_) {
      _setOnline(false);
    } finally {
      _probing = false;
    }
  }
}
