import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, Platform;
import 'dart:math' show asin, cos, pi, sin, sqrt;

import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart' show closeInAppWebView;
import 'package:uuid/uuid.dart';

import 'net_status.dart';
import 'push_service.dart';
import 'signup_rules.dart';

/// Same Vercel deployment the website talks to — the two API routes
/// (check-device, get-video-url) work identically for native app requests
/// since CORS is a browser-only restriction.
const String kApiBaseUrl = 'https://site-and-structure.vercel.app';

// Paused pre-launch: every OTPIQ send costs money, so signup/launch skip the
// phone-verify step entirely (no request to send-phone-otp is ever made)
// until this flips back to true. Flip it, rebuild, and every new signup
// goes through phone verification again.
const bool kPhoneOtpEnabled = true;

// Teacher/admin sign-in needs a 6-digit code emailed through the custom
// SMTP (Resend). Turn off to fall back to password only.
const bool kTeacherAdminEmailOtpEnabled = true;

/// Every account must sign in again this long after signing in, however
/// actively it uses the app (session timeout).
const Duration kSessionMaxAge = Duration(days: 5);
const String _signedInAtKey = 'ss_signed_in_at';

/// Version stored with each terms acceptance (profiles.terms_version).
/// Bump it when the terms change in a way users must agree to again.
const String kTermsVersion = '2026-10-05';

const String kSupabaseUrl = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const String kSupabaseAnonKey =
    'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';

const String _deviceIdKey = 'ss_device_id';
const String _sessionTokenKey = 'ss_session_token';
// "Remember my login" on the sign-in form. flutter_secure_storage keeps
// these in the Android Keystore / iOS Keychain (encrypted, app-private),
// never in plain SharedPreferences.
const String _savedEmailKey = 'ss_saved_login_email';
const String _savedPasswordKey = 'ss_saved_login_password';

/// Result of login() / verifyLoginEmailCode(): either it's done (success),
/// it failed (error, an i18n key or a raw message), or the password checked
/// out but a teacher/admin account still needs the emailed 6-digit code
/// (needsEmailOtp + email), checked by verifyLoginEmailCode().
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

  // resetOnError: after an app reinstall signed with a different key (debug
  // vs release builds), Android can no longer decrypt what was stored, and
  // every read throws. Starting clean is the only way out -- otherwise
  // sign-in crashes after the password was already accepted.
  final _secureStorage = const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: true));
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
  ///
  /// Android now uses ANDROID_ID ("aid-..."): unique per device and stable
  /// across reinstalls of the same app. The old "android-<Build.ID>" value
  /// was the OS build number -- identical on every device running the same
  /// Android version and different after every OS update -- so it both let
  /// devices share a slot and made a reinstalled phone look brand new. The
  /// old value is reported as [legacyDeviceId] so check-device can move the
  /// existing slot over instead of counting the device twice.
  String? legacyDeviceId;
  bool _deviceIdMigrated = false;

  Future<String> getDeviceId() async {
    String? cached;
    try {
      cached = await _secureStorage.read(key: _deviceIdKey);
    } catch (_) {}
    if (!kIsWeb && Platform.isAndroid) {
      String? aid;
      try {
        aid = await const AndroidId().getId();
      } catch (_) {}
      if (aid != null && aid.isNotEmpty) {
        final id = 'aid-$aid';
        if (cached != id) {
          String? legacy = cached;
          if (legacy == null) {
            try {
              final info = await DeviceInfoPlugin().androidInfo;
              if (info.id.isNotEmpty) legacy = 'android-${info.id}';
            } catch (_) {}
          }
          legacyDeviceId = legacy;
          _deviceIdMigrated = true;
          try {
            await _secureStorage.write(key: _deviceIdKey, value: id);
          } catch (_) {}
        }
        return id;
      }
    }
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
    try {
      await _secureStorage.write(key: _deviceIdKey, value: id);
    } catch (_) {}
    return id;
  }

  Future<bool> _isDeviceAllowed(String accessToken) async {
    final deviceId = await getDeviceId();
    final res = await http
        .post(
      Uri.parse('$kApiBaseUrl/api/check-device'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({
        'deviceId': deviceId,
        'deviceLabel': 'Flutter app',
        if (legacyDeviceId != null && legacyDeviceId != deviceId)
          'legacyDeviceId': legacyDeviceId,
      }),
    )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw HttpException('check-device ${res.statusCode}');
    }
    final result = jsonDecode(res.body) as Map<String, dynamic>;
    if (result['allowed'] != true) return false;
    _sessionTokenMemory = result['sessionToken'] as String;
    try {
      await _secureStorage.write(
          key: _sessionTokenKey, value: result['sessionToken'] as String);
    } catch (_) {}
    _startSessionWatch();
    return true;
  }

  /// Kept in memory too, so a storage hiccup can't make this device look
  /// like a different one.
  String? _sessionTokenMemory;

  Future<String?> getSessionToken() async {
    try {
      return await _secureStorage.read(key: _sessionTokenKey) ??
          _sessionTokenMemory;
    } catch (_) {
      return _sessionTokenMemory;
    }
  }

  /// Saved sign-in details for the login form, or null if none are saved.
  Future<({String email, String password})?> getSavedLogin() async {
    try {
      final email = await _secureStorage.read(key: _savedEmailKey);
      final password = await _secureStorage.read(key: _savedPasswordKey);
      if (email == null || password == null) return null;
      return (email: email, password: password);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLogin(String email, String password) async {
    await _secureStorage.write(key: _savedEmailKey, value: email.trim());
    await _secureStorage.write(key: _savedPasswordKey, value: password.trim());
  }

  Future<void> clearSavedLogin() async {
    await _secureStorage.delete(key: _savedEmailKey);
    await _secureStorage.delete(key: _savedPasswordKey);
  }

  void _startSessionWatch() {
    _sessionWatchTimer?.cancel();
    _sessionWatchTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      final user = currentUser;
      if (user == null) return;
      // A recovery session never claimed a device slot, so its token can't
      // match -- without this the user is "kicked" mid-way through typing
      // their new password.
      if (_inPasswordRecovery) return;
      if (await enforceSessionLimit()) return;
      try {
      var myToken = await getSessionToken();
      if (myToken == null) {
        // This device never finished its device check (e.g. the network
        // dropped right after the password was accepted). Claim the slot
        // now instead of treating it as "signed in elsewhere".
        final access = client.auth.currentSession?.accessToken;
        if (access != null && await _isDeviceAllowed(access)) return;
        myToken = await getSessionToken();
      }
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
        _sessionTokenMemory = null;
        try {
          await _secureStorage.delete(key: _sessionTokenKey);
        } catch (_) {}
        notifyListeners();
        onForcedLogout?.call();
      }
      } catch (_) {
        // Offline or a transient error: check again on the next tick rather
        // than signing anyone out over it.
      }
    });
  }

  void stopSessionWatch() {
    _sessionWatchTimer?.cancel();
    _sessionWatchTimer = null;
  }

  /// Set by the UI layer to show the "kicked by another device" message.
  void Function()? onForcedLogout;

  static const _flagDistanceKm = 150;

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
  /// Starts the 5-day sign-in clock. Called from _logLoginEvent, which every
  /// successful sign-in path (password, Google, email link, sign-up) runs.
  Future<void> _markSignedIn() async {
    try {
      await _secureStorage.write(
          key: _signedInAtKey, value: DateTime.now().toUtc().toIso8601String());
    } catch (_) {}
  }

  /// Signs the user out once kSessionMaxAge has passed since they
  /// signed in. A session from before this rule existed starts its
  /// clock now. Returns true if it signed the user out.
  Future<bool> enforceSessionLimit() async {
    final user = currentUser;
    if (user == null || _inPasswordRecovery) return false;
    String? raw;
    try {
      raw = await _secureStorage.read(key: _signedInAtKey);
    } catch (_) {}
    final at = DateTime.tryParse(raw ?? '');
    if (at == null) {
      await _markSignedIn();
      return false;
    }
    if (DateTime.now().toUtc().difference(at) < kSessionMaxAge) {
      return false;
    }
    await logout();
    try {
      await _secureStorage.delete(key: _signedInAtKey);
    } catch (_) {}
    onSessionExpired?.call();
    return true;
  }

  /// Shown when the 5-day session ends (set from main.dart).
  void Function()? onSessionExpired;

  Future<void> _logLoginEvent(String userId, String email) async {
    unawaited(_markSignedIn());
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
    String? flagReason;
    int? distanceKm;

    try {
      if (lat != null && lon != null) {
        final prev = await client
            .from('login_events')
            .select('lat, lon, created_at')
            .eq('user_id', userId)
            .not('lat', 'is', null)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();
        final prevLat = (prev?['lat'] as num?)?.toDouble();
        final prevLon = (prev?['lon'] as num?)?.toDouble();
        if (prevLat != null && prevLon != null) {
          distanceKm = _distanceKm(prevLat, prevLon, lat, lon).round();
          // Impossible travel: far apart within a short time. Small jumps
          // are normal on Iraqi mobile networks and no longer flagged.
          final prevAt = DateTime.tryParse(prev?['created_at'] as String? ?? '');
          final hours = prevAt == null
              ? 999.0
              : DateTime.now().toUtc().difference(prevAt.toUtc()).inMinutes / 60;
          if (distanceKm > _flagDistanceKm && hours < 2) {
            flagged = true;
            flagReason = 'travel';
          }
        }
      }
      final country = geo['country_code'] as String?;
      if (country != null && country != 'IQ') {
        flagged = true;
        flagReason = 'outside_iraq';
      }

      final row = {
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
      };
      try {
        await client
            .from('login_events')
            .insert({...row, if (flagReason != null) 'flag_reason': flagReason});
      } on PostgrestException {
        // flag_reason column not added yet (add-oct05-fixes.sql).
        await client.from('login_events').insert(row);
      }
    } catch (_) {
      // Audit logging must never block login itself.
    }
  }

  /// Teacher/admin accounts can publish paid content and see revenue, so a
  /// leaked password alone shouldn't be enough to get in -- every login for
  /// those two roles needs a 6-digit code emailed to the account, on top of
  /// the password (or Google). Regular students are unaffected.
  Future<bool> _requiresLoginEmailOtp(String userId) async {
    if (!kTeacherAdminEmailOtpEnabled) return false;
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
    bool allowed;
    try {
      allowed = await _isDeviceAllowed(accessToken);
    } catch (_) {
      // Password was right but the device check couldn't complete: don't
      // leave a half-signed-in session behind (it would later be "kicked").
      await client.auth.signOut().catchError((_) {});
      return const LoginResult(error: 'err_login_network');
    }
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
      final res = await client.auth
          .signInWithPassword(email: trimmedEmail, password: password.trim())
          .timeout(const Duration(seconds: 20));
      final user = res.user;
      if (user == null) return const LoginResult(error: 'Login failed.');

      if (await _requiresLoginEmailOtp(user.id)) {
        // Password confirmed but not enough on its own for this role --
        // drop the session; verifyLoginEmailCode() grants one once the
        // emailed code is typed in.
        await client.auth.signOut();
        final err = await _sendLoginEmailCode(trimmedEmail);
        if (err != null) return LoginResult(error: err);
        return LoginResult(needsEmailOtp: true, email: trimmedEmail);
      }

      return await _finishPasswordLogin(res, trimmedEmail);
    } on AuthException catch (e) {
      return LoginResult(error: e.message);
    } catch (_) {
      return const LoginResult(error: 'err_login_network');
    }
  }

  /// Emails the 6-digit sign-in code (Supabase "Magic link or OTP"
  /// template, which shows only {{ .Token }}). Never creates an account.
  Future<String?> _sendLoginEmailCode(String email) async {
    try {
      await client.auth.signInWithOtp(email: email, shouldCreateUser: false);
      return null;
    } on AuthException catch (e) {
      if (e.statusCode == '429') return 'err_otp_wait';
      return e.message;
    } catch (_) {
      return 'err_login_network';
    }
  }

  /// Sends a fresh code (the user asked for a new one).
  Future<String?> resendLoginEmailOtp(String email) => _sendLoginEmailCode(email);

  /// Checks the typed code; on success finishes the sign-in exactly like a
  /// plain password login (device cap, login log).
  Future<LoginResult> verifyLoginEmailCode(String email, String code) async {
    final token = code.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^\d{6}$').hasMatch(token)) {
      return const LoginResult(error: 'err_otp_incorrect');
    }
    try {
      final res = await client.auth
          .verifyOTP(email: email, token: token, type: OtpType.email)
          .timeout(const Duration(seconds: 20));
      if (res.session == null || res.user == null) {
        return const LoginResult(error: 'err_otp_incorrect');
      }
      return await _finishPasswordLogin(res, email);
    } on AuthException catch (e) {
      final m = e.message.toLowerCase();
      if (m.contains('expired')) return const LoginResult(error: 'err_otp_expired');
      if (e.statusCode == '429') {
        return const LoginResult(error: 'err_otp_too_many_attempts');
      }
      return const LoginResult(error: 'err_otp_incorrect');
    } catch (_) {
      return const LoginResult(error: 'err_login_network');
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
    final normalizedPhone = SignupRules.normalizeIraqiPhone(phone);
    if (normalizedPhone == null) return 'err_phone_format';
    if (!SignupRules.isValidEmailShape(email)) return 'err_invalid_email';
    if (!SignupRules.isAllowedEmailDomain(email)) return 'err_email_domain';
    if (!SignupRules.isStrongPassword(password.trim())) return 'err_pass_weak';
    try {
      // One account per phone number: checked before the account exists, so
      // a taken number never leaves a half-created account behind.
      final free = await client
          .rpc('is_phone_available', params: {'p_phone': normalizedPhone})
          .timeout(const Duration(seconds: 15));
      if (free != true) return 'err_phone_taken';
      final res = await client.auth.signUp(
        email: email.trim(),
        password: password.trim(),
        data: {'full_name': name.trim(), 'phone': normalizedPhone},
      );
      final user = res.user;
      // An email that already has an account comes back as a user with no
      // identities (Supabase hides it rather than erroring).
      if (user != null && (user.identities?.isEmpty ?? false)) {
        return 'err_email_taken';
      }
      final accessToken = res.session?.accessToken;
      if (user == null || accessToken == null) return 'Sign up failed.';

      // If this fails the auth account exists without a profile. Sign out
      // so the user isn't left half signed-in; on the next sign-in the
      // complete-profile step creates the profile row (it upserts).
      try {
        await saveProfileBasics(
            id: user.id, name: name.trim(), phone: normalizedPhone);
      } on PostgrestException catch (e) {
        await client.auth.signOut().catchError((_) {});
        return e.code == '23505' ? 'err_phone_taken' : 'err_login_network';
      } catch (_) {
        await client.auth.signOut().catchError((_) {});
        return 'err_login_network';
      }

      bool allowed;
      try {
        allowed = await _isDeviceAllowed(accessToken);
      } catch (_) {
        await client.auth.signOut().catchError((_) {});
        return 'err_login_network';
      }
      if (!allowed) {
        await client.auth.signOut();
        return 'err_device_limit';
      }
      unawaited(_logLoginEvent(user.id, user.email ?? email.trim()));
      unawaited(recordTermsAcceptance());
      notifyListeners();
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (_) {
      return 'err_login_network';
    }
  }

  // Deep-link scheme the OAuth browser hands the session back to (registered
  // in AndroidManifest.xml / Info.plist). signInWithOAuth() only launches the
  // browser and returns once that's done -- the actual session arrives later
  // through this same redirect, picked up by supabase_flutter's own deep
  // link listener and surfaced as an AuthChangeEvent.signedIn below.
  static const String kGoogleRedirectUrl = 'siteandstructure://login-callback';
  Completer<LoginResult>? _oauthCompleter;

  /// Sign in with Apple (iPhone only; Apple requires it next to Google).
  /// Turn on once the Apple provider is set up in Supabase (Services ID,
  /// key, team ID), otherwise the button would open an error page.
  static const bool kAppleSignInEnabled = false;

  /// On iPhone the sign-in page opens inside the app (Apple rejects apps
  /// that send users out to Safari to log in) and is closed here once the
  /// deep link lands. Android keeps the external browser.
  bool get _oauthInApp => !kIsWeb && Platform.isIOS;

  void _closeOAuthBrowser() {
    if (_oauthInApp) unawaited(closeInAppWebView().catchError((_) {}));
  }

  /// Call once at app start (see main.dart) so a Google sign-in started from
  /// anywhere has somewhere to report back to once the deep link lands.
  void listenForOAuthCompletion() {
    client.auth.onAuthStateChange.listen((state) async {
      final completer = _oauthCompleter;
      if (completer == null || completer.isCompleted) return;
      if (state.event != AuthChangeEvent.signedIn) return;
      _oauthCompleter = null;
      _closeOAuthBrowser();

      final session = state.session;
      final user = session?.user;
      if (session == null || user == null) {
        completer.complete(const LoginResult(error: 'Login failed.'));
        return;
      }
      try {
        {
          // Only google/password signUp() ever creates the profiles row; a
          // first-time Google sign-in needs the same row or every profile /
          // is_teacher / phone_verified lookup elsewhere just sees null.
          // Only inserted when missing, so a returning user's own edited
          // name/bio is never clobbered by Google's claims on a later login.
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

          // Same emailed-code gate password login goes through -- otherwise
          // a teacher/admin could skip it just by using Google instead.
          final email = user.email ?? '';
          if (email.isNotEmpty && await _requiresLoginEmailOtp(user.id)) {
            await client.auth.signOut();
            final err = await _sendLoginEmailCode(email);
            if (err != null) {
              completer.complete(LoginResult(error: err));
              return;
            }
            completer.complete(LoginResult(needsEmailOtp: true, email: email));
            return;
          }
        }

        final allowed = await _isDeviceAllowed(session.accessToken);
        if (!allowed) {
          await client.auth.signOut();
          completer.complete(const LoginResult(error: 'err_device_limit'));
          return;
        }
        unawaited(_logLoginEvent(user.id, user.email ?? ''));
        notifyListeners();
        completer.complete(const LoginResult(success: true));
      } catch (e) {
        // Google accepted the account but the device check (or profile
        // setup) failed: never leave a half-signed-in session behind.
        await client.auth.signOut().catchError((_) {});
        completer.complete(const LoginResult(error: 'err_login_network'));
      }
    }, onError: (Object e) {
      // A failed Google/email-link return (expired, already used). Without
      // this the waiting screen sat until its 5-minute timeout, and the
      // error escaped as "uncaught".
      final completer = _oauthCompleter;
      if (completer == null || completer.isCompleted) return;
      _oauthCompleter = null;
      _closeOAuthBrowser();
      _linkErrorShownByWaiter = true;
      completer.complete(const LoginResult(error: 'err_link_expired'));
    });
  }

  /// Resolves once the OAuth deep link actually lands (see
  /// listenForOAuthCompletion), not when the browser merely opens -- same
  /// LoginResult contract as login(), including the email-link step for
  /// teacher/admin accounts.
  /// Web OAuth client of Google Cloud project arc-platform-39b9e (the one
  /// Supabase's Google provider uses). Native sign-in asks Google for an ID
  /// token for this client, so Supabase accepts it. Client IDs are public.
  static const String kGoogleWebClientId =
      '982425355302-nn9u5ksh0jhmv44cd8vvv049bbc69ad0.apps.googleusercontent.com';
  bool _googleInitialized = false;
  // While the native account picker runs, the auth screen's "came back
  // without a session" check must not cancel the attempt.
  bool _nativeGoogleInProgress = false;

  /// Android: Google's own account picker, then Supabase signInWithIdToken;
  /// the Google page shows "Arc Platform" instead of the supabase.co address.
  /// Anything other than the user cancelling falls back to the browser flow,
  /// so a configuration problem can never block sign-in. iPhone keeps the
  /// in-app browser until an iOS OAuth client exists.
  Future<LoginResult> signInWithGoogle() async {
    if (kIsWeb || !Platform.isAndroid) {
      return _signInWithOAuth(OAuthProvider.google);
    }
    final String? idToken;
    _nativeGoogleInProgress = true;
    try {
      final g = GoogleSignIn.instance;
      if (!_googleInitialized) {
        await g.initialize(serverClientId: kGoogleWebClientId);
        _googleInitialized = true;
      }
      final account = await g.authenticate();
      idToken = account.authentication.idToken;
      // Next time the picker shows every account again.
      unawaited(g.signOut().catchError((_) {}));
    } on GoogleSignInException catch (e) {
      _nativeGoogleInProgress = false;
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        return const LoginResult(error: 'err_oauth_cancelled');
      }
      debugPrint('google: native sign-in failed (${e.code}), using browser');
      return _signInWithOAuth(OAuthProvider.google);
    } catch (e) {
      _nativeGoogleInProgress = false;
      debugPrint('google: native sign-in failed ($e), using browser');
      return _signInWithOAuth(OAuthProvider.google);
    }
    if (idToken == null) {
      _nativeGoogleInProgress = false;
      return _signInWithOAuth(OAuthProvider.google);
    }
    // Same completion path as the browser flow: listenForOAuthCompletion
    // picks up the signedIn event (profile row, staff email code, device).
    final completer = Completer<LoginResult>();
    _oauthCompleter = completer;
    try {
      await client.auth
          .signInWithIdToken(provider: OAuthProvider.google, idToken: idToken);
    } on AuthException catch (e) {
      _oauthCompleter = null;
      _nativeGoogleInProgress = false;
      return LoginResult(error: e.message);
    } catch (_) {
      _oauthCompleter = null;
      _nativeGoogleInProgress = false;
      return const LoginResult(error: 'err_login_network');
    }
    try {
      return await completer.future.timeout(const Duration(seconds: 60),
          onTimeout: () {
        _oauthCompleter = null;
        return const LoginResult(error: 'err_login_network');
      });
    } finally {
      _nativeGoogleInProgress = false;
    }
  }

  /// Same flow as Google (profile row, staff email code, device check).
  Future<LoginResult> signInWithApple() => _signInWithOAuth(OAuthProvider.apple);

  Future<LoginResult> _signInWithOAuth(OAuthProvider provider) async {
    final completer = Completer<LoginResult>();
    _oauthCompleter = completer;
    try {
      await client.auth.signInWithOAuth(
        provider,
        redirectTo: kGoogleRedirectUrl,
        authScreenLaunchMode: _oauthInApp
            ? LaunchMode.inAppBrowserView
            : LaunchMode.externalApplication,
      );
    } on AuthException catch (e) {
      _oauthCompleter = null;
      return LoginResult(error: e.message);
    }
    return completer.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        _oauthCompleter = null;
        _closeOAuthBrowser();
        return const LoginResult(error: 'err_oauth_cancelled');
      },
    );
  }

  /// The user came back from the Google page without finishing: end the
  /// attempt now instead of leaving the sign-in screen locked for minutes.
  void cancelGoogleSignIn() {
    if (_nativeGoogleInProgress) return;
    final c = _oauthCompleter;
    if (c == null || c.isCompleted) return;
    _oauthCompleter = null;
    _closeOAuthBrowser();
    c.complete(const LoginResult(error: 'err_oauth_cancelled'));
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
  /// Name and phone on the profile row, creating the row if it isn't there
  /// yet (a sign-up cut off half way). Users may only write a short list of
  /// profile columns (full_name, phone, ...): writing anything else here --
  /// an upsert that sets id, or the terms columns -- is refused by the
  /// database and made registration fail.
  Future<void> saveProfileBasics({
    required String id,
    required String name,
    required String phone,
  }) async {
    final updated = await client
        .from('profiles')
        .update({'full_name': name, 'phone': phone})
        .eq('id', id)
        .select('id');
    if ((updated as List).isEmpty) {
      await client
          .from('profiles')
          .insert({'id': id, 'full_name': name, 'phone': phone});
    }
  }

  /// Stores that this user agreed to the terms (version + time). Goes through
  /// a database function because users can't write those columns directly.
  /// Best effort: never blocks sign-up.
  Future<void> recordTermsAcceptance() async {
    try {
      await client.rpc('record_terms_acceptance',
          params: {'p_version': kTermsVersion});
    } catch (_) {}
  }

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
      // Back to the app, not the Site URL: supabase_flutter uses PKCE, so
      // the reset link can only be exchanged on the device that asked for
      // it (the code verifier lives in this app's storage). Same deep link
      // already allow-listed for Google sign-in.
      await client.auth
          .resetPasswordForEmail(email.trim(), redirectTo: kGoogleRedirectUrl);
      return null;
    } on AuthException catch (e) {
      return e.message;
    }
  }

  // --- Password recovery -------------------------------------------------
  //
  // Opening the reset link signs the user in with a *recovery* session
  // (AuthChangeEvent.passwordRecovery). That session skipped the device cap
  // and the teacher/admin email step, so it's only ever used to set the new
  // password: afterwards (or if abandoned) it's signed out and the user logs
  // in normally, where both checks apply.

  static const _recoveryPendingKey = 'password_recovery_pending';
  bool _inPasswordRecovery = false;
  bool _linkErrorShownByWaiter = false;
  bool get inPasswordRecovery => _inPasswordRecovery;

  /// Call once at app start, before resumeSessionWatchIfLoggedIn().
  /// [onRecovery] shows the set-new-password screen. onAuthStateChange is a
  /// replay stream, so a link that cold-started the app (handled inside
  /// Supabase.initialize, before this runs) is still delivered here.
  Future<void> listenForPasswordRecovery(
      void Function() onRecovery, void Function() onLinkExpired) async {
    var recoveryThisLaunch = false;
    client.auth.onAuthStateChange.listen((state) async {
      if (state.event != AuthChangeEvent.passwordRecovery) return;
      recoveryThisLaunch = true;
      _inPasswordRecovery = true;
      await _secureStorage.write(key: _recoveryPendingKey, value: '1');
      onRecovery();
    }, onError: (Object e) {
      // An expired or already-used email link (reset or sign-in) comes back
      // as otp_expired. Say so, or the app just opens on Home and the link
      // looks broken. Other auth errors (network etc.) stay silent here.
      // listenForOAuthCompletion's subscription runs first (registered
      // first); if a waiting screen already showed the error, don't repeat
      // it in a dialog.
      final shownByWaiter = _linkErrorShownByWaiter;
      _linkErrorShownByWaiter = false;
      if (shownByWaiter) return;
      if (e is AuthException &&
          (e.statusCode == 'otp_expired' || e.code == 'otp_expired')) {
        onLinkExpired();
      }
    });
    // Let replayed events arrive first, then clear a recovery session left
    // over from a previous launch (app killed mid-reset) so it can never be
    // used as a normal login.
    await Future<void>.delayed(Duration.zero);
    if (!recoveryThisLaunch &&
        await _secureStorage.read(key: _recoveryPendingKey) != null) {
      await endPasswordRecovery();
    }
  }

  /// Sets the new password on the recovery session, then signs out
  /// everywhere (anyone holding the old password loses their session too).
  Future<String?> setNewPassword(String password) async {
    if (!_inPasswordRecovery || client.auth.currentSession == null) {
      return 'err_reset_expired';
    }
    if (!SignupRules.isStrongPassword(password)) return 'err_pass_weak';
    try {
      await client.auth.updateUser(UserAttributes(password: password));
    } on AuthException catch (e) {
      if (e.code == 'same_password') return 'err_same_password';
      if (e.code == 'weak_password') return 'err_pass_weak';
      return e.message;
    }
    // A saved old password would just fail on the next login.
    await clearSavedLogin();
    await endPasswordRecovery(everywhere: true);
    return null;
  }

  Future<void> endPasswordRecovery({bool everywhere = false}) async {
    _inPasswordRecovery = false;
    await _secureStorage.delete(key: _recoveryPendingKey);
    stopSessionWatch();
    await _secureStorage.delete(key: _sessionTokenKey);
    try {
      await client.auth.signOut(
          scope: everywhere ? SignOutScope.global : SignOutScope.local);
    } catch (_) {
      // Global sign-out needs the network; the local session is cleared
      // regardless, which is what matters on this device.
      await client.auth.signOut(scope: SignOutScope.local);
    }
    notifyListeners();
  }

  Future<void> logout() async {
    // This phone stops receiving the account's notifications.
    await PushService.instance.unregister();
    stopSessionWatch();
    _sessionTokenMemory = null;
    try {
      await _secureStorage.delete(key: _sessionTokenKey);
      await _secureStorage.delete(key: _signedInAtKey);
    } catch (_) {}
    try {
      // Offline, signOut clears the local session and then throws: the
      // user is signed out on this device either way.
      await client.auth.signOut();
    } catch (_) {
    } finally {
      notifyListeners();
    }
  }

  /// Permanently deletes the current user's account server-side (see
  /// api/delete-account.js), then clears the local session the same way
  /// logout() does. Returns an error string (untranslated key) on failure,
  /// null on success.
  Future<String?> deleteAccount() async {
    final session = client.auth.currentSession;
    if (session == null) return 'err_delete_account_failed';
    try {
      final res = await http
          .post(
            Uri.parse('$kApiBaseUrl/api/delete-account'),
            headers: {'Authorization': 'Bearer ${session.accessToken}'},
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return 'err_delete_account_failed';
    } catch (e) {
      return NetStatus.isOffline(e) ? 'err_offline' : 'err_delete_account_failed';
    }
    await clearSavedLogin();
    stopSessionWatch();
    try {
      await _secureStorage.delete(key: _sessionTokenKey);
      await client.auth.signOut();
    } catch (_) {
    } finally {
      notifyListeners();
    }
    return null;
  }

  /// Admin only: permanently deletes another account (and, for a teacher,
  /// their courses) through api/delete-account.js. Returns an error string
  /// key on failure, null on success.
  Future<String?> adminDeleteAccount(String userId) async {
    final session = client.auth.currentSession;
    if (session == null) return 'err_delete_account_failed';
    try {
      final res = await http
          .post(
            Uri.parse('$kApiBaseUrl/api/delete-account'),
            headers: {
              'Authorization': 'Bearer ${session.accessToken}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'userId': userId}),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 403) return 'err_not_allowed';
      if (res.statusCode != 200) return 'err_delete_account_failed';
      return null;
    } catch (e) {
      return NetStatus.isOffline(e) ? 'err_offline' : 'err_delete_account_failed';
    }
  }

  /// Call once at app start if a session was restored from disk, to resume
  /// the session-watch loop (mirrors updateAuthUI() calling startSessionWatch
  /// on the website whenever a session is found).
  void resumeSessionWatchIfLoggedIn() {
    if (!isLoggedIn) return;
    _startSessionWatch();
    unawaited(enforceSessionLimit());
    // Already signed in from before the device-id change: re-register this
    // device under its new id now (the server moves the old slot), so video
    // playback -- which checks the device id -- keeps working without a
    // fresh sign-in.
    unawaited(() async {
      await getDeviceId();
      final access = client.auth.currentSession?.accessToken;
      if (_deviceIdMigrated && access != null) {
        try {
          await _isDeviceAllowed(access);
        } catch (_) {}
      }
    }());
  }
}
