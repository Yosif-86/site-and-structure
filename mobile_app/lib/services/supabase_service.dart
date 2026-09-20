import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' show asin, cos, pi, sin, sqrt;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Same Vercel deployment the website talks to — the two API routes
/// (check-device, get-video-url) work identically for native app requests
/// since CORS is a browser-only restriction.
const String kApiBaseUrl = 'https://site-and-structure.vercel.app';

// Paused pre-launch: every OTPIQ send costs money, so signup/launch skip the
// phone-verify step entirely (no request to send-phone-otp is ever made)
// until this flips back to true. Flip it, rebuild, and every new signup
// goes through phone verification again.
const bool kPhoneOtpEnabled = false;

const String kSupabaseUrl = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const String kSupabaseAnonKey =
    'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';

const String _deviceIdKey = 'ss_device_id';
const String _sessionTokenKey = 'ss_session_token';

/// Result of login() / verifyLoginEmailOtp(): either it's done (success),
/// it failed (error, an i18n key or a raw message), or the password checked
/// out but a teacher/admin account still needs its email code
/// (needsEmailOtp + email) before verifyLoginEmailOtp() can finish it.
class LoginResult {
  final bool success;
  final bool needsEmailOtp;
  final String? email;
  final String? error;
  const LoginResult(
      {this.success = false, this.needsEmailOtp = false, this.email, this.error});
}

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

  /// A stable per-physical-device identifier for the device cap: Android's
  /// ANDROID_ID / iOS's identifierForVendor, both scoped to this app by the
  /// OS and both designed by their platforms specifically for anti-abuse
  /// device identification (no extra permission, not the same as an
  /// advertising ID, doesn't identify the person). Unlike a random UUID
  /// generated once and cached in secure storage, this survives an
  /// uninstall/reinstall -- so re-installing the app can't silently mint a
  /// "new device" and eat into the one-device-per-account cap.
  ///
  /// A device that already has a cached UUID from before this change keeps
  /// using it -- switching everyone over immediately would make every
  /// already-installed app look like a brand-new device to trusted_devices
  /// and could cap out users who are already logged in. Only a device with
  /// no cached value (a genuinely fresh or post-uninstall install) computes
  /// the new stable id, which is exactly the case this is meant to fix.
  Future<String> getDeviceId() async {
    final cached = await _secureStorage.read(key: _deviceIdKey);
    if (cached != null) return cached;

    String? id;
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      try {
        final deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final info = await deviceInfo.androidInfo;
          if (info.id.isNotEmpty) id = 'android-${info.id}';
        } else {
          final info = await deviceInfo.iosInfo;
          final vendorId = info.identifierForVendor;
          if (vendorId != null && vendorId.isNotEmpty) id = 'ios-$vendorId';
        }
      } catch (_) {
        // Fall through to the random-UUID fallback below.
      }
    }
    id ??= const Uuid().v4();
    await _secureStorage.write(key: _deviceIdKey, value: id);
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
    await _secureStorage.write(
        key: _sessionTokenKey, value: result['sessionToken'] as String);
    _startSessionWatch();
    return true;
  }

  Future<String?> getSessionToken() =>
      _secureStorage.read(key: _sessionTokenKey);

  void _startSessionWatch() {
    _sessionWatchTimer?.cancel();
    _sessionWatchTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      final user = currentUser;
      if (user == null) return;
      final myToken = await _secureStorage.read(key: _sessionTokenKey);
      final row = await client
          .from('profiles')
          .select('active_session_token')
          .eq('id', user.id)
          .maybeSingle();
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

  static const _flagDistanceKm = 10;

  double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return r * 2 * asin(sqrt(a));
  }

  /// Port of logLoginEvent() in index.html — same IP-geolocation lookup and
  /// >10km-from-last-login flagging, so mobile logins show up in the admin
  /// dashboard's flagged-logins view exactly like web ones do.
  Future<void> _logLoginEvent(String userId, String email) async {
    Map<String, dynamic> geo = {};
    try {
      final res = await http
          .get(Uri.parse('https://ipapi.co/json/'))
          .timeout(const Duration(seconds: 8));
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
        'user_agent':
            'Flutter app (${kIsWeb ? 'web' : Platform.operatingSystem})',
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

  /// Teacher/admin accounts can publish paid content and see revenue, so a
  /// leaked password alone shouldn't be enough to get in -- every login for
  /// those two roles needs a one-time email code as a second factor, on top
  /// of the password. Regular students are unaffected.
  Future<bool> _requiresLoginEmailOtp(String userId) async {
    try {
      final prof = await client
          .from('profiles')
          .select('is_teacher, is_admin')
          .eq('id', userId)
          .maybeSingle();
      return prof?['is_teacher'] == true || prof?['is_admin'] == true;
    } catch (_) {
      // A failed role lookup falls back to the pre-2FA behavior (plain
      // password login) rather than locking anyone out over a transient
      // read error -- every other gate (RLS, server-side role checks) still
      // applies regardless, so this only affects whether the extra email
      // step is asked for.
      return false;
    }
  }

  Future<LoginResult> _finishPasswordLogin(
      AuthResponse res, String emailFallback) async {
    final accessToken = res.session?.accessToken;
    final user = res.user;
    if (accessToken == null || user == null) {
      return const LoginResult(error: 'Login failed.');
    }
    final allowed = await _isDeviceAllowed(accessToken);
    if (!allowed) {
      await client.auth.signOut();
      return const LoginResult(error: 'err_device_limit');
    }
    unawaited(_logLoginEvent(user.id, user.email ?? emailFallback));
    notifyListeners();
    return const LoginResult(success: true);
  }

  Future<LoginResult> login(String email, String password) async {
    if (email.trim().isEmpty || password.trim().isEmpty) {
      return const LoginResult(error: 'err_enter_email_pass');
    }
    final trimmedEmail = email.trim();
    try {
      final res = await client.auth.signInWithPassword(
          email: trimmedEmail, password: password.trim());
      final user = res.user;
      if (user == null) return const LoginResult(error: 'Login failed.');

      if (await _requiresLoginEmailOtp(user.id)) {
        // Password confirmed but not enough on its own for this role --
        // drop the session and only grant one once the email code checks
        // out too, in verifyLoginEmailOtp() below.
        await client.auth.signOut();
        try {
          await client.auth
              .signInWithOtp(email: trimmedEmail, shouldCreateUser: false);
        } on AuthException catch (e) {
          return LoginResult(error: e.message);
        }
        return LoginResult(needsEmailOtp: true, email: trimmedEmail);
      }

      return await _finishPasswordLogin(res, trimmedEmail);
    } on AuthException catch (e) {
      return LoginResult(error: e.message);
    }
  }

  /// Resends the login email code (e.g. the user asked for a new one) --
  /// same call as the one login() makes the first time.
  Future<String?> resendLoginEmailOtp(String email) async {
    try {
      await client.auth.signInWithOtp(email: email, shouldCreateUser: false);
      return null;
    } on AuthException catch (e) {
      return e.message;
    }
  }

  /// Completes the login started by login() once it returned
  /// LoginResult.needsEmailOtp -- verifying the code itself establishes the
  /// session (no password re-entry needed), which then goes through the
  /// same device-cap/login-log finish as an ordinary login.
  Future<LoginResult> verifyLoginEmailOtp(String email, String code) async {
    try {
      final res = await client.auth
          .verifyOTP(email: email, token: code, type: OtpType.email);
      if (res.session == null || res.user == null) {
        return const LoginResult(error: 'err_otp_incorrect');
      }
      return await _finishPasswordLogin(res, email);
    } on AuthException catch (e) {
      return LoginResult(error: e.message);
    }
  }

  Future<String?> signUp({
    required String name,
    required String phone,
    required String email,
    required String password,
  }) async {
    if (name.trim().isEmpty ||
        phone.trim().isEmpty ||
        email.trim().isEmpty ||
        password.trim().isEmpty) {
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

      await client.from('profiles').insert(
          {'id': user.id, 'full_name': name.trim(), 'phone': phone.trim()});

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

  // Deep-link scheme the OAuth browser hands the session back to (registered
  // in AndroidManifest.xml / Info.plist). signInWithOAuth() only launches the
  // browser and returns once that's done -- the actual session arrives later
  // through this same redirect, picked up by supabase_flutter's own deep
  // link listener and surfaced as an AuthChangeEvent.signedIn below.
  static const String kGoogleRedirectUrl = 'siteandstructure://login-callback';
  Completer<LoginResult>? _oauthCompleter;

  /// Call once at app start (see main.dart) so a Google sign-in started from
  /// anywhere has somewhere to report back to once the deep link lands.
  void listenForOAuthCompletion() {
    client.auth.onAuthStateChange.listen((state) async {
      final completer = _oauthCompleter;
      if (completer == null || completer.isCompleted) return;
      if (state.event != AuthChangeEvent.signedIn) return;
      _oauthCompleter = null;

      final session = state.session;
      final user = session?.user;
      if (session == null || user == null) {
        completer.complete(const LoginResult(error: 'Login failed.'));
        return;
      }
      try {
        // Only google/password signUp() ever creates the profiles row; a
        // first-time Google sign-in needs the same row or every profile /
        // is_teacher / phone_verified lookup elsewhere just sees null. Only
        // inserted when missing, so a returning user's own edited name/bio
        // is never clobbered by Google's claims on a later login.
        final existing = await client
            .from('profiles')
            .select('id')
            .eq('id', user.id)
            .maybeSingle();
        if (existing == null) {
          final meta = user.userMetadata ?? {};
          await client.from('profiles').insert({
            'id': user.id,
            'full_name': meta['full_name'] ?? meta['name'] ?? '',
          });
        }

        // Same email-OTP gate password login goes through -- otherwise a
        // teacher/admin could skip it entirely just by using Google instead.
        final email = user.email ?? '';
        if (email.isNotEmpty && await _requiresLoginEmailOtp(user.id)) {
          await client.auth.signOut();
          try {
            await client.auth
                .signInWithOtp(email: email, shouldCreateUser: false);
          } on AuthException catch (e) {
            completer.complete(LoginResult(error: e.message));
            return;
          }
          completer.complete(LoginResult(needsEmailOtp: true, email: email));
          return;
        }

        final allowed = await _isDeviceAllowed(session.accessToken);
        if (!allowed) {
          await client.auth.signOut();
          completer.complete(const LoginResult(error: 'err_device_limit'));
          return;
        }
        unawaited(_logLoginEvent(user.id, email));
        notifyListeners();
        completer.complete(const LoginResult(success: true));
      } catch (e) {
        completer.complete(const LoginResult(error: 'Login failed.'));
      }
    });
  }

  /// Resolves once the OAuth deep link actually lands (see
  /// listenForOAuthCompletion), not when the browser merely opens -- same
  /// LoginResult contract as login(), including the email-OTP step for
  /// teacher/admin accounts.
  Future<LoginResult> signInWithGoogle() async {
    final completer = Completer<LoginResult>();
    _oauthCompleter = completer;
    try {
      await client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: kGoogleRedirectUrl,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
    } on AuthException catch (e) {
      _oauthCompleter = null;
      return LoginResult(error: e.message);
    }
    return completer.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        _oauthCompleter = null;
        return const LoginResult(error: 'err_oauth_cancelled');
      },
    );
  }

  /// Pre-check before showing the invite as accepted -- admin.html generates
  /// these tokens, mirrors is_teacher_invite_valid()'s use on the website.
  /// Returns null if the check itself failed (network/RPC error), distinct
  /// from a definite false (dead token).
  Future<bool?> checkTeacherInviteValid(String token) async {
    try {
      final res =
          await client.rpc('is_teacher_invite_valid', params: {'p_token': token});
      return res == true;
    } catch (_) {
      return null;
    }
  }

  /// Grants teacher status for a just-created account. Best-effort by
  /// design, same as the website's redeem_teacher_invite() call -- a
  /// revoked/expired/already-used token must never undo the signup that
  /// already succeeded; it just means this account stays a normal student.
  Future<void> redeemTeacherInvite(String token) async {
    try {
      await client.rpc('redeem_teacher_invite', params: {'p_token': token});
    } catch (_) {
      // Best-effort -- see above.
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

  /// Permanently deletes the current user's account server-side (see
  /// api/delete-account.js), then clears the local session the same way
  /// logout() does. Returns an error string (untranslated key) on failure,
  /// null on success.
  Future<String?> deleteAccount() async {
    final session = client.auth.currentSession;
    if (session == null) return 'err_delete_account_failed';
    final res = await http.post(
      Uri.parse('$kApiBaseUrl/api/delete-account'),
      headers: {'Authorization': 'Bearer ${session.accessToken}'},
    );
    if (res.statusCode != 200) return 'err_delete_account_failed';
    stopSessionWatch();
    await _secureStorage.delete(key: _sessionTokenKey);
    await client.auth.signOut();
    notifyListeners();
    return null;
  }

  /// Call once at app start if a session was restored from disk, to resume
  /// the session-watch loop (mirrors updateAuthUI() calling startSessionWatch
  /// on the website whenever a session is found).
  void resumeSessionWatchIfLoggedIn() {
    if (isLoggedIn) _startSessionWatch();
  }
}
