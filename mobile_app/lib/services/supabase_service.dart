import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Same Vercel deployment the website talks to — the two API routes
/// (check-device, get-video-url) work identically for native app requests
/// since CORS is a browser-only restriction.
const String kApiBaseUrl = 'https://site-and-structure.vercel.app';

const String kSupabaseUrl = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const String kSupabaseAnonKey = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';

const String _deviceIdKey = 'ss_device_id';
const String _sessionTokenKey = 'ss_session_token';

/// Auth + device-cap/session-watch service. Direct port of the logic spread
/// across index.html's checkDeviceAndClaimSession()/startSessionWatch() and
/// the equivalent in course.html.
class SupabaseService extends ChangeNotifier {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get client => Supabase.instance.client;

  Timer? _sessionWatchTimer;

  static Future<void> init() async {
    await Supabase.initialize(url: kSupabaseUrl, anonKey: kSupabaseAnonKey);
  }

  User? get currentUser => client.auth.currentUser;
  bool get isLoggedIn => currentUser != null;

  Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  Future<bool> _isDeviceAllowed(String accessToken) async {
    final deviceId = await _getDeviceId();
    final res = await http.post(
      Uri.parse('$kApiBaseUrl/api/check-device'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'deviceId': deviceId, 'deviceLabel': 'Flutter app'}),
    );
    if (res.statusCode != 200) return false;
    final result = jsonDecode(res.body) as Map<String, dynamic>;
    if (result['allowed'] != true) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionTokenKey, result['sessionToken'] as String);
    _startSessionWatch();
    return true;
  }

  void _startSessionWatch() {
    _sessionWatchTimer?.cancel();
    _sessionWatchTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      final user = currentUser;
      if (user == null) return;
      final prefs = await SharedPreferences.getInstance();
      final myToken = prefs.getString(_sessionTokenKey);
      final row = await client.from('profiles').select('active_session_token').eq('id', user.id).maybeSingle();
      final serverToken = row?['active_session_token'] as String?;
      if (serverToken != myToken) {
        _sessionWatchTimer?.cancel();
        _sessionWatchTimer = null;
        await client.auth.signOut();
        await prefs.remove(_sessionTokenKey);
        notifyListeners();
        onForcedLogout?.call();
      }
    });
  }

  void stopSessionWatch() {
    _sessionWatchTimer?.cancel();
    _sessionWatchTimer = null;
  }

  /// Set by the UI layer to show the "kicked by another device" message.
  void Function()? onForcedLogout;

  /// Returns null on success, or an error message.
  Future<String?> login(String email, String password) async {
    if (email.trim().isEmpty || password.trim().isEmpty) return 'err_enter_email_pass';
    try {
      final res = await client.auth.signInWithPassword(email: email.trim(), password: password.trim());
      final accessToken = res.session?.accessToken;
      if (accessToken == null) return 'Login failed.';
      final allowed = await _isDeviceAllowed(accessToken);
      if (!allowed) {
        await client.auth.signOut();
        return 'err_device_limit';
      }
      notifyListeners();
      return null;
    } on AuthException catch (e) {
      return e.message;
    }
  }

  Future<String?> signUp({
    required String name,
    required String phone,
    required String email,
    required String password,
  }) async {
    if (name.trim().isEmpty || phone.trim().isEmpty || email.trim().isEmpty || password.trim().isEmpty) {
      return 'err_fill_fields';
    }
    if (password.trim().length < 6) return 'err_pass_length';
    try {
      final res = await client.auth.signUp(
        email: email.trim(),
        password: password.trim(),
        data: {'full_name': name.trim(), 'phone': phone.trim()},
      );
      final user = res.user;
      final accessToken = res.session?.accessToken;
      if (user == null || accessToken == null) return 'Sign up failed.';

      await client.from('profiles').insert({'id': user.id, 'full_name': name.trim(), 'phone': phone.trim()});

      final allowed = await _isDeviceAllowed(accessToken);
      if (!allowed) {
        await client.auth.signOut();
        return 'err_device_limit';
      }
      notifyListeners();
      return null;
    } on AuthException catch (e) {
      return e.message;
    }
  }

  Future<String?> sendPasswordReset(String email) async {
    if (email.trim().isEmpty) return 'err_enter_email';
    try {
      await client.auth.resetPasswordForEmail(email.trim());
      return null;
    } on AuthException catch (e) {
      return e.message;
    }
  }

  Future<void> logout() async {
    stopSessionWatch();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionTokenKey);
    await client.auth.signOut();
    notifyListeners();
  }

  /// Call once at app start if a session was restored from disk, to resume
  /// the session-watch loop (mirrors updateAuthUI() calling startSessionWatch
  /// on the website whenever a session is found).
  void resumeSessionWatchIfLoggedIn() {
    if (isLoggedIn) _startSessionWatch();
  }
}
