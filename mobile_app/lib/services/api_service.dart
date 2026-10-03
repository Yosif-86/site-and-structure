import 'dart:convert';

import 'package:http/http.dart' as http;

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
  static Future<OtpResult> sendPhoneOtp(String accessToken,
      {String? phone}) async {
    final res = await http.post(
      Uri.parse('$kApiBaseUrl/api/send-phone-otp'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({if (phone != null) 'phone': phone}),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      return OtpResult(
          ok: false, error: body['error'] as String? ?? 'err_otp_send_failed');
    }
    return OtpResult(ok: true);
  }

  static Future<OtpResult> verifyPhoneOtp(
      String accessToken, String code) async {
    final res = await http.post(
      Uri.parse('$kApiBaseUrl/api/verify-phone-otp'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'code': code}),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      return OtpResult(
          ok: false, error: body['error'] as String? ?? 'err_otp_incorrect');
    }
    return OtpResult(ok: true);
  }

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
