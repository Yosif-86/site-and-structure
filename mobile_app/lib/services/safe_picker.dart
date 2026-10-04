import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

/// Gallery picks that ignore a second tap while one picker is already open.
/// A double tap used to throw "already_active" (seen in the error log).
class SafePicker {
  static bool _busy = false;

  static Future<XFile?> image({int imageQuality = 85}) => _run(() =>
      ImagePicker().pickImage(
          source: ImageSource.gallery, imageQuality: imageQuality));

  static Future<XFile?> video() =>
      _run(() => ImagePicker().pickVideo(source: ImageSource.gallery));

  static Future<XFile?> _run(Future<XFile?> Function() pick) async {
    if (_busy) return null;
    _busy = true;
    try {
      return await pick();
    } on PlatformException catch (e) {
      if (e.code == 'already_active') return null;
      rethrow;
    } finally {
      _busy = false;
    }
  }
}
