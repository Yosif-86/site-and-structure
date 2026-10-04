import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'supabase_service.dart';

/// Thrown when [R2Upload.cancel] stops an upload.
class UploadCancelled implements Exception {
  const UploadCancelled();
}

/// Uploads a lecture video straight to Cloudflare R2 in 8 MB parts.
///
/// api/r2-upload.js checks the teacher owns the course and signs a token
/// for exactly one object (videos/<lectureId>/source.mp4); the Cloudflare
/// Worker then writes each part into R2 through its own bucket binding, so
/// no storage keys ever reach the phone and there is no file-size cap. Only
/// one part is in memory at a time, progress moves as R2 confirms parts,
/// each part retries on a weak connection, and [cancel] aborts cleanly.
class R2Upload {
  static const _partSize = 8 * 1024 * 1024; // R2 needs equal parts >= 5 MB
  // A part gets 7 tries with growing waits (about 2.5 minutes in total), so
  // a phone switching networks or a short dead zone doesn't fail the whole
  // upload.
  static const _retries = 7;
  static const _backoff = [3, 6, 12, 20, 40, 60];

  final String courseId;
  final String lectureId;
  final File file;

  R2Upload({required this.courseId, required this.lectureId, required this.file});

  /// The object key once uploaded, e.g. videos/<id>/source.mp4.
  String get key => 'videos/$lectureId/source.mp4';

  final http.Client _client = http.Client();
  bool _cancelled = false;
  String? _base;
  Map<String, String>? _auth;
  String? _uploadId;

  void cancel() {
    _cancelled = true;
    _client.close();
    _abort();
  }

  void _check() {
    if (_cancelled) throw const UploadCancelled();
  }

  Future<void> _authorize({bool refresh = false}) async {
    if (refresh) {
      try {
        await SupabaseService.instance.client.auth.refreshSession();
      } catch (_) {}
    }
    final token =
        SupabaseService.instance.client.auth.currentSession?.accessToken;
    final res = await _client.post(
      Uri.parse('$kApiBaseUrl/api/r2-upload'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(
          {'action': 'upload', 'courseId': courseId, 'lectureId': lectureId}),
    );
    if (res.statusCode != 200) {
      throw HttpException('authorize failed (${res.statusCode}): ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    _base = body['url'] as String;
    _auth = {
      'token': body['token'] as String,
      'expires': '${body['expires']}',
      'uid': body['uid'] as String,
    };
  }

  Uri _uri(Map<String, String> q) =>
      Uri.parse(_base!).replace(queryParameters: {..._auth!, ...q});

  Future<void> start(void Function(double progress) onProgress) async {
    final total = await file.length();
    final raf = await file.open();
    try {
      await _authorize();
      _check();
      final create = await _client.post(_uri({'op': 'create'}));
      if (create.statusCode != 200) {
        throw HttpException('create failed (${create.statusCode}): ${create.body}');
      }
      _uploadId = (jsonDecode(create.body) as Map)['uploadId'] as String;

      final parts = <Map<String, dynamic>>[];
      var offset = 0;
      var partNumber = 1;
      onProgress(0);
      while (offset < total) {
        _check();
        final size = (total - offset) < _partSize ? total - offset : _partSize;
        await raf.setPosition(offset);
        final Uint8List bytes = await raf.read(size);
        final etag = await _putPart(partNumber, bytes);
        parts.add({'partNumber': partNumber, 'etag': etag});
        offset += size;
        partNumber++;
        onProgress(offset / total);
      }

      _check();
      final done = await _client.post(
        _uri({'op': 'complete', 'uploadId': _uploadId!}),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(parts),
      );
      if (done.statusCode != 200) {
        throw HttpException('complete failed (${done.statusCode}): ${done.body}');
      }
    } on http.ClientException {
      if (_cancelled) throw const UploadCancelled();
      _abort();
      rethrow;
    } on UploadCancelled {
      rethrow;
    } catch (_) {
      // Failed for good: free the parts already stored in R2.
      _abort();
      rethrow;
    } finally {
      await raf.close();
      if (!_cancelled) _client.close();
    }
  }

  Future<String> _putPart(int partNumber, Uint8List bytes) async {
    for (var attempt = 1;; attempt++) {
      _check();
      try {
        final res = await _client
            .put(
              _uri({
                'op': 'part',
                'uploadId': _uploadId!,
                'partNumber': '$partNumber',
              }),
              headers: {'Content-Type': 'application/octet-stream'},
              body: bytes,
            )
            .timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          return (jsonDecode(res.body) as Map)['etag'] as String;
        }
        // Upload permission expired (very long upload): get a fresh one.
        if (res.statusCode == 401 || res.statusCode == 403) {
          await _authorize(refresh: true);
        }
        throw HttpException('part $partNumber failed (${res.statusCode})');
      } catch (e) {
        if (_cancelled) throw const UploadCancelled();
        if (attempt >= _retries) rethrow;
        await Future.delayed(
            Duration(seconds: _backoff[(attempt - 1).clamp(0, _backoff.length - 1)]));
      }
    }
  }

  /// Best effort: frees the parts already stored for an abandoned upload.
  void _abort() {
    final id = _uploadId;
    if (id == null || _base == null) return;
    http.post(_uri({'op': 'abort', 'uploadId': id})).catchError(
        (_) => http.Response('', 500));
  }

  /// Admin rejecting an uploaded lecture: deletes its file from R2.
  static Future<void> deleteObject(String lectureId) async {
    final token =
        SupabaseService.instance.client.auth.currentSession?.accessToken;
    final res = await http.post(
      Uri.parse('$kApiBaseUrl/api/r2-upload'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'action': 'delete', 'lectureId': lectureId}),
    );
    if (res.statusCode != 200) return;
    final b = jsonDecode(res.body) as Map<String, dynamic>;
    await http.post(Uri.parse(b['url'] as String).replace(queryParameters: {
      'token': b['token'] as String,
      'expires': '${b['expires']}',
      'uid': b['uid'] as String,
    }));
  }
}
