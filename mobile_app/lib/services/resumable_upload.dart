import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'supabase_service.dart';

/// Thrown when [ResumableUpload.cancel] stops an upload.
class UploadCancelled implements Exception {
  const UploadCancelled();
}

/// Thrown when Storage rejects the file for its size (bucket / plan limit).
class UploadTooLarge implements Exception {
  const UploadTooLarge();
}

/// Uploads a file to Supabase Storage with the TUS resumable protocol, in
/// 6 MB chunks (the chunk size Supabase requires).
///
/// Why not one big POST: lecture videos run to hundreds of MB. The previous
/// streamed POST read the file as fast as the disk allowed and queued it all
/// in memory, which crashed the app on large videos and made the progress
/// ring track disk reads instead of what had actually been sent. Here only
/// one chunk is in memory at a time, progress moves when the server confirms
/// a chunk, each chunk is retried on a flaky connection, and [cancel] stops
/// cleanly between or during chunks.
class ResumableUpload {
  static const _chunk = 6 * 1024 * 1024;
  static const _retries = 3;

  final String bucket;
  final String objectPath;
  final File file;
  final String contentType;

  ResumableUpload({
    required this.bucket,
    required this.objectPath,
    required this.file,
    this.contentType = 'video/mp4',
  });

  http.Client? _client;
  bool _cancelled = false;
  String? _location;

  void cancel() {
    _cancelled = true;
    _client?.close();
  }

  Map<String, String> _headers() {
    final token =
        SupabaseService.instance.client.auth.currentSession!.accessToken;
    return {
      'apikey': kSupabaseAnonKey,
      'Authorization': 'Bearer $token',
      'Tus-Resumable': '1.0.0',
    };
  }

  String _b64(String s) => base64.encode(utf8.encode(s));

  Future<void> start(void Function(double progress) onProgress) async {
    final total = await file.length();
    _client = http.Client();
    final raf = await file.open();
    try {
      // 1. Create the upload.
      final create = await _client!.post(
        Uri.parse('$kSupabaseUrl/storage/v1/upload/resumable'),
        headers: {
          ..._headers(),
          'Upload-Length': '$total',
          'x-upsert': 'false',
          'Upload-Metadata': [
            'bucketName ${_b64(bucket)}',
            'objectName ${_b64(objectPath)}',
            'contentType ${_b64(contentType)}',
            'cacheControl ${_b64('3600')}',
          ].join(','),
        },
      );
      _throwIfCancelled();
      if (create.statusCode == 413) throw const UploadTooLarge();
      if (create.statusCode != 201) {
        throw HttpException(
            'create failed (${create.statusCode}): ${create.body}');
      }
      final loc = create.headers['location'];
      if (loc == null) throw const HttpException('no upload location');
      _location = loc.startsWith('http') ? loc : '$kSupabaseUrl$loc';

      // 2. Send it chunk by chunk.
      var offset = 0;
      onProgress(0);
      while (offset < total) {
        _throwIfCancelled();
        final size = (total - offset) < _chunk ? total - offset : _chunk;
        await raf.setPosition(offset);
        final Uint8List bytes = await raf.read(size);
        offset = await _patch(bytes, offset);
        onProgress(offset / total);
      }
    } on http.ClientException {
      if (_cancelled) throw const UploadCancelled();
      rethrow;
    } finally {
      await raf.close();
      _client?.close();
      _client = null;
    }
  }

  Future<int> _patch(Uint8List bytes, int offset) async {
    for (var attempt = 1;; attempt++) {
      _throwIfCancelled();
      try {
        final res = await _client!.patch(
          Uri.parse(_location!),
          headers: {
            ..._headers(),
            'Upload-Offset': '$offset',
            'Content-Type': 'application/offset+octet-stream',
          },
          body: bytes,
        );
        if (res.statusCode == 413) throw const UploadTooLarge();
        if (res.statusCode == 204) {
          return int.tryParse(res.headers['upload-offset'] ?? '') ??
              offset + bytes.length;
        }
        throw HttpException('chunk failed (${res.statusCode}): ${res.body}');
      } on UploadTooLarge {
        rethrow;
      } catch (e) {
        if (_cancelled) throw const UploadCancelled();
        if (attempt >= _retries) rethrow;
        await Future.delayed(Duration(seconds: 2 * attempt));
        // The server may have stored part of the failed chunk; ask where to
        // resume from instead of assuming.
        final head = await _client!
            .head(Uri.parse(_location!), headers: _headers())
            .catchError((_) => http.Response('', 500));
        final serverOffset = int.tryParse(head.headers['upload-offset'] ?? '');
        if (serverOffset != null && serverOffset > offset) {
          return serverOffset;
        }
      }
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) throw const UploadCancelled();
  }
}
