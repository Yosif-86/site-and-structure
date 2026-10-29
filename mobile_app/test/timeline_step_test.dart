import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_and_structure/widgets/timeline_step.dart';

void main() {
  testWidgets('timeline steps lay out, animate and open on tap',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    var open = 0;
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                for (var i = 0; i < 3; i++)
                  TimelineStep(
                    number: i + 1,
                    title: 'Step ${i + 1}',
                    subtitle: 'sub',
                    status: 'status',
                    done: i < open,
                    open: i == open,
                    last: i == 2,
                    locked: false,
                    onTap: () => setState(() => open = i),
                    child: Container(height: 220, color: Colors.red),
                  ),
              ]),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(Container).evaluate().isNotEmpty, isTrue);
    await tester.tap(find.text('Step 2'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Step 3'));
    await tester.pump(const Duration(milliseconds: 900));
    expect(open, 2);
    expect(tester.takeException(), isNull);
  });
}
