import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_and_structure/widgets/tablet_frame.dart';

void main() {
  Future<void> pump(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: TabletFrame(child: SizedBox.expand(key: Key('content'))),
    ));
  }

  testWidgets('phone width is untouched', (tester) async {
    await pump(tester, 400);
    expect(tester.getSize(find.byKey(const Key('content'))).width, 400);
  });

  testWidgets('tablet width becomes a centred column', (tester) async {
    await pump(tester, 1024);
    expect(tester.getSize(find.byKey(const Key('content'))).width,
        TabletFrame.maxContentWidth);
  });

  testWidgets('full bleed lifts the limit', (tester) async {
    TabletFrame.fullBleed.value = 1;
    addTearDown(() => TabletFrame.fullBleed.value = 0);
    await pump(tester, 1024);
    expect(tester.getSize(find.byKey(const Key('content'))).width, 1024);
  });
}
