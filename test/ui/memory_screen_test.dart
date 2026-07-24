import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/ui/memory_screen.dart';
import 'package:under_claw_work/ui/status_pill.dart';

import 'test_support.dart';

void main() {
  setUpAll(loadRealFonts);

  late Directory root;

  setUp(() => root = seedManagementWorkspace());
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> pump(
    WidgetTester tester, {
    Brightness b = Brightness.dark,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1120, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(b),
        home: MemoryRecallScreen(workspaceRoot: root),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> recallDomain(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextField, 'Domain ID'),
      'DOM-mgmt',
    );
    await tester.tap(find.textContaining('Recall'));
    await tester.pumpAndSettle();
  }

  testWidgets('recalls current and superseded knowledge with provenance', (
    tester,
  ) async {
    await pump(tester);
    await recallDomain(tester);
    expect(find.text('Registry is Git-canonical'), findsWidgets);
    expect(find.text('current'), findsWidgets);
    expect(find.text('superseded'), findsWidgets);
    // Provenance chip proves how the item entered scope.
    expect(find.textContaining('via: scope'), findsWidgets);
    expect(find.byType(StatusPill), findsWidgets);
  });

  testWidgets('restricted recall is fail-closed without a capability issuer', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await recallDomain(tester);
    // The service refuses; nothing restricted is shown, the error is surfaced.
    expect(find.textContaining('Restricted recall requires'), findsWidgets);
  });

  testWidgets('include-restricted checkbox is a labelled, operable control '
      '(a11y)', (tester) async {
    await pump(tester);
    // A semantics tree builds without error (assistive tech can traverse it).
    final handle = tester.ensureSemantics();
    // It carries a visible, accessible name.
    expect(find.text('Include restricted (fail-closed)'), findsOneWidget);
    // And it is a real, toggleable control — starts unchecked, toggles on tap.
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    handle.dispose();
  });

  testWidgets('renders in light theme without error (a11y)', (tester) async {
    await pump(tester, b: Brightness.light);
    await recallDomain(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Registry is Git-canonical'), findsWidgets);
  });

  testWidgets('Memory recall screen matches golden', (tester) async {
    await pump(tester);
    await recallDomain(tester);
    await expectLater(
      find.byType(MemoryRecallScreen),
      matchesGoldenFile('goldens/memory_screen.png'),
    );
  }, tags: 'golden');
}
