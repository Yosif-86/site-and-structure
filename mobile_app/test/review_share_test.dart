import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_and_structure/widgets/review_share_sheet.dart';

void main() {
  testWidgets('review share card renders in every theme without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    for (final review in [
      {'rating': 5, 'comment': 'شرح مرتب وسهل', 'student_name': 'أحمد'},
      {'rating': 4, 'comment': '', 'student_name': 'Yosif'},
      {'rating': 3, 'comment': 'x' * 400, 'student_name': 'Sara'},
    ]) {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => showReviewShare(c,
                review: review.cast<String, dynamic>(), courseTitle: 'Course'),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        final swatches = find.byType(InkWell);
        await tester.tap(swatches.at(i + 0).hitTestable(), warnIfMissed: false);
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
    }
  });
}
