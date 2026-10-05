import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/painting.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Draws the student's name and phone on every page of a downloaded PDF:
/// a faint diagonal line across the middle and a small line at the bottom,
/// so a shared copy shows whose it was.
///
/// The text is drawn by Flutter (correct Arabic shaping in the app's own
/// font) into a transparent PNG, then placed on the pages. Writing it as
/// PDF text instead drops Arabic letters: the PDF library needs isolated
/// letter forms that the Alexandria font doesn't have.
class PdfStamp {
  static Future<Uint8List> stamp(Uint8List pdf, String mark) async {
    final png = await markPng(mark);
    return compute(_stamp, (pdf: pdf, png: png));
  }

  /// The mark as a grey, transparent PNG (rendered at a high size so it
  /// stays sharp when printed).
  static Future<Uint8List> markPng(String mark) async {
    final painter = TextPainter(
      text: TextSpan(
        text: mark,
        style: const TextStyle(
          fontFamily: 'ArcArabic',
          fontSize: 96,
          color: Color(0xFF6E6E6E),
        ),
      ),
      textDirection: TextDirection.rtl,
    )..layout();
    final w = painter.width.ceil() + 8, h = painter.height.ceil() + 8;
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Offset(4, 4));
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  static Uint8List stampSync(Uint8List pdf, Uint8List png) =>
      _stamp((pdf: pdf, png: png));
}

Uint8List _stamp(({Uint8List pdf, Uint8List png}) a) {
  final doc = PdfDocument(inputBytes: a.pdf);
  try {
    final mark = PdfBitmap(a.png);
    final ratio = mark.width / mark.height;
    for (var i = 0; i < doc.pages.count; i++) {
      final page = doc.pages[i];
      final size = page.getClientSize();
      final w = size.width, h = size.height;
      final g = page.graphics;

      // Footer: small, readable when printed.
      final fh = (w * 0.018).clamp(7.0, 12.0);
      final fw = fh * ratio;
      g.save();
      g.setTransparency(0.85);
      g.drawImage(mark, ui.Rect.fromLTWH((w - fw) / 2, h - fh - 8, fw, fh));
      g.restore();

      // Diagonal across the middle, faint enough not to block the content.
      final dw = w * 0.8;
      final dh = dw / ratio;
      g.save();
      g.setTransparency(0.16);
      g.translateTransform(w / 2, h / 2);
      g.rotateTransform(-35);
      g.drawImage(mark, ui.Rect.fromLTWH(-dw / 2, -dh / 2, dw, dh));
      g.restore();
    }
    return Uint8List.fromList(doc.saveSync());
  } finally {
    doc.dispose();
  }
}
