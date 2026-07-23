import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/main.dart';

void main() {
  testWidgets('empty workspace renders native desktop shell', (tester) async {
    final temporary = Directory.systemTemp.createTempSync('under-claw-widget-');
    addTearDown(() => temporary.deleteSync(recursive: true));

    await tester.pumpWidget(UnderClawWorkApp(workspaceOverride: temporary));
    await tester.pumpAndSettle();

    expect(find.text('Under Claw Work'), findsOneWidget);
    expect(find.text('No tasks yet'), findsOneWidget);
  });
}
