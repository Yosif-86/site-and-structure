import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_and_structure/services/pdf_stamp.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  testWidgets('stamps the name and phone on every page', (tester) async {
    final font = File('assets/google_fonts/Alexandria-Regular.ttf').readAsBytesSync();
    await tester.runAsync(() => (FontLoader('ArcArabic')
          ..addFont(Future.value(ByteData.view(font.buffer))))
        .load());

    final src = PdfDocument();
    src.pages.add().graphics.drawString(
        'Page one', PdfStandardFont(PdfFontFamily.helvetica, 18),
        bounds: const Rect.fromLTWH(40, 40, 300, 30));
    src.pageSettings.orientation = PdfPageOrientation.landscape;
    src.pages.add();
    final input = Uint8List.fromList(src.saveSync());
    src.dispose();

    final png = (await tester.runAsync(
        () => PdfStamp.markPng('يوسف جمال علي · 07701234567')))!;
    final out = PdfStamp.stampSync(input, png);

    final path = Platform.environment['STAMP_OUT'];
    if (path != null) File(path).writeAsBytesSync(out);

    final doc = PdfDocument(inputBytes: out);
    expect(doc.pages.count, 2);
    expect(PdfTextExtractor(doc).extractText(), contains('Page one'));
    doc.dispose();
    expect(out.length, greaterThan(input.length + png.length));
  });
}
