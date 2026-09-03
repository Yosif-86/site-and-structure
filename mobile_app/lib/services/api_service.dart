import 'dart:convert';

import 'package:http/http.dart' as http;

import 'supabase_service.dart';

class VideoUrlResult {
  final String? url;
  final String? type; // 'hls' | 'bunny'
  final String? error;
  VideoUrlResult({this.url, this.type, this.error});
}

class ApiService {
  static Future<VideoUrlResult> getVideoUrl(String lectureId, String accessToken) async {
    final deviceId = await SupabaseService.instance.getDeviceId();
    final sessionToken = await SupabaseService.instance.getSessionToken();
    final res = await http.post(
      Uri.parse('$kApiBaseUrl/api/get-video-url'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'lectureId': lectureId, 'deviceId': deviceId, 'sessionToken': sessionToken}),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      return VideoUrlResult(error: body['error'] as String? ?? 'err_video_unavailable');
    }
    return VideoUrlResult(url: body['url'] as String?, type: body['type'] as String?);
  }
}
