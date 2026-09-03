import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' show asin, cos, pi, sin, sqrt;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
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

  final _secureStorage = const FlutterSecureStorage();
  Timer? _sessionWatchTimer;

  static Future<void> init() async {
    await Supabase.initialize(url: kSupabaseUrl, anonKey: kSupabaseAnonKey);
  }

  User? get currentUser => client.auth.currentUser;
  bool get isLoggedIn => currentUser != null;

  Future<String> getDeviceId() async {
    var id = await _secureStorage.read(key: _deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await _secureStorage.write(key: _deviceIdKey, value: id);
    }
    return id;
  }

  Future<bool> _isDeviceAllowed(String accessToken) async {
    final deviceId = await getDeviceId();
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
    await _secureStorage.write(key: _sessionTokenKey, value: result['sessionToken'] as String);
    _startSessionWatch();
    return true;
  }

  Future<String?> getSessionToken() => _secureStorage.read(key: _sessionTokenKey);

  void _startSessionWatch() {
    _sessionWatchTimer?.cancel();
    _sessionWatchTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      final user = currentUser;
      if (user == null) return;
      final myToken = await _secureStorage.read(key: _sessionTokenKey);
      final row = await client.from('profiles').select('active_session_token').eq('id', user.id).maybeSingle();
      final serverToken = row?['active_session_token'] as String?;
      if (serverToken != myToken) {
        _sessionWatchTimer?.cancel();
        _sessionWatchTimer = null;
        await client.auth.signOut();
        await _secureStorage.delete(key: _sessionTokenKey);
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

  static const _flagDistanceKm = 300;

  double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
    return r * 2 * asin(sqrt(a));
  }

  /// Port of logLoginEvent() in index.html — same IP-geolocation lookup and
  /// >300km-from-last-login flagging, so mobile logins show up in the admin
  /// dashboard's flagged-logins view exactly like web ones do.
  Future<void> _logLoginEvent(String userId, String email) async {
    Map<String, dynamic> geo = {};
    try {
      final res = await http.get(Uri.parse('https://ipapi.co/json/')).timeout(const Duration(seconds: 8));
      geo = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      // Location lookup failed — log without it, same as the website does.
    }

    final lat = (geo['latitude'] as num?)?.toDouble();
    final lon = (geo['longitude'] as num?)?.toDouble();
    bool flagged = false;
    int? distanceKm;

    try {
      if (lat != null && lon != null) {
        final prev = await client
            .from('login_events')
            .select('lat, lon')
            .eq('user_id', userId)
            .not('lat', 'is', null)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();
        final prevLat = (prev?['lat'] as num?)?.toDouble();
        final prevLon = (prev?['lon'] as num?)?.toDouble();
        if (prevLat != null && prevLon != null) {
          distanceKm = _distanceKm(prevLat, prevLon, lat, lon).round();
          flagged = distanceKm > _flagDistanceKm;
        }
      }

      await client.from('login_events').insert({
        'user_id': userId,
        'email': email,
        'user_agent': 'Flutter app (${kIsWeb ? 'web' : Platform.operatingSystem})',
        'ip': geo['ip'],
        'city': geo['city'],
        'country': geo['country_name'],
        'lat': lat,
        'lon': lon,
        'flagged': flagged,
        'distance_km': distanceKm,
      });
    } catch (_) {
      // Audit logging must never block login itself.
    }
  }

  /// Returns null on success, or an error message.
  Future<String?> login(String email, String password) async {
    if (email.trim().isEmpty || password.trim().isEmpty) return 'err_enter_email_pass';
    try {
      final res = await client.auth.signInWithPassword(email: email.trim(), password: password.trim());
      final accessToken = res.session?.accessToken;
      final user = res.user;
      if (accessToken == null || user == null) return 'Login failed.';
      final allowed = await _isDeviceAllowed(accessToken);
      if (!allowed) {
        await client.auth.signOut();
        return 'err_device_limit';
      }
      unawaited(_logLoginEvent(user.id, user.email ?? email.trim()));
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
      unawaited(_logLoginEvent(user.id, user.email ?? email.trim()));
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
    await _secureStorage.delete(key: _sessionTokenKey);
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
