import 'dart:convert';

import 'package:http/http.dart' as http;

import 'net_status.dart';
import 'supabase_service.dart';

class VideoUrlResult {
  final String? url;
  final String? type; // 'hls'
  final String? error;
  final int? statusCode;
  VideoUrlResult({this.url, this.type, this.error, this.statusCode});
}

class OtpResult {
  final bool ok;
  final String? error;
  OtpResult({required this.ok, this.error});
}

class ApiService {
  /// Posts to one of our /api functions and never throws: offline, timeouts,
  /// and non-JSON error pages (e.g. a Vercel 504) all come back as an error
  /// key the screen can show, so no spinner is left running forever.
  static Future<OtpResult> _otpCall(String path, String accessToken,
      Map<String, dynamic> payload, String fallbackError) async {
    try {
      final res = await http
          .post(
            Uri.parse('$kApiBaseUrl/api/$path'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 25));
      if (res.statusCode == 200) return OtpResult(ok: true);
      String? err;
      try {
        err = (jsonDecode(res.body) as Map<String, dynamic>)['error'] as String?;
      } catch (_) {}
      return OtpResult(ok: false, error: err ?? fallbackError);
    } catch (e) {
      if (NetStatus.isOffline(e)) {
        NetStatus.instance.reportOffline();
        return OtpResult(ok: false, error: 'err_offline');
      }
      return OtpResult(ok: false, error: fallbackError);
    }
  }

  static Future<OtpResult> sendPhoneOtp(String accessToken, {String? phone}) =>
      _otpCall('send-phone-otp', accessToken,
          {if (phone != null) 'phone': phone}, 'err_otp_send_failed');

  static Future<OtpResult> verifyPhoneOtp(String accessToken, String code) =>
      _otpCall('verify-phone-otp', accessToken, {'code': code},
          'err_otp_verify_failed');

  /// Starts the background 480p/720p/1080p conversion of a lecture the
  /// admin just approved (api/convert-lecture.js). Best effort: if it fails
  /// the lecture simply stays a single 1080p video.
  static Future<void> startLectureConversion(
      String lectureId, String accessToken) async {
    try {
      await http
          .post(
            Uri.parse('$kApiBaseUrl/api/convert-lecture'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode({'lectureId': lectureId}),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  static Future<VideoUrlResult> getVideoUrl(
      String lectureId, String accessToken, {bool preview = false}) async {
    final deviceId = await SupabaseService.instance.getDeviceId();
    final sessionToken = await SupabaseService.instance.getSessionToken();
    final res = await http.post(
      Uri.parse('$kApiBaseUrl/api/get-video-url'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({
        'lectureId': lectureId,
        'deviceId': deviceId,
        'sessionToken': sessionToken,
        if (preview) 'preview': true,
      }),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      return VideoUrlResult(
          error: body['error'] as String? ?? 'err_video_unavailable',
          statusCode: res.statusCode);
    }
    return VideoUrlResult(
        url: body['url'] as String?, type: body['type'] as String?);
  }
}
