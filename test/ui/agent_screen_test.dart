import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';
import 'package:under_claw_work/ui/agent_screen.dart';
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
    await tester.binding.setSurfaceSize(const Size(1120, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(b),
        home: AgentManagementScreen(workspaceRoot: root),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists agents from AgentRegistryService (Core, not a mock)', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Hermes'), findsWidgets);
    expect(find.text('Athena'), findsWidgets);
    // Status is paired with a StatusPill (icon + text), never colour alone.
    expect(find.byType(StatusPill), findsWidgets);
    expect(find.text('active'), findsWidgets);
  });

  testWidgets('rename writes through the service and survives a reload', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Hermes').first);
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Name').first;
    await tester.enterText(field, 'Hermes Prime');
    await tester.tap(find.text('Save name'));
    await tester.pumpAndSettle();
    // The canonical registry now carries the new name (id unchanged).
    final reloaded = AgentRegistryService(Workspace(root)).get('AGT-hermes');
    expect(reloaded!.name, 'Hermes Prime');
  });

  testWidgets('deactivate toggles status through the service', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Hermes').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deactivate'));
    await tester.pumpAndSettle();
    expect(
      AgentRegistryService(Workspace(root)).get('AGT-hermes')!.status,
      'inactive',
    );
  });

  testWidgets('keyboard shortcut Ctrl+N invokes the register action (a11y)', (
    tester,
  ) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    // The register dialog opened purely from the keyboard.
    expect(find.text('Register agent'), findsOneWidget);
  });

  testWidgets('command buttons expose Semantics labels (a11y)', (tester) async {
    await pump(tester);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.bySemanticsLabel('Register agent')),
      isNotNull,
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Refresh agents')),
      isNotNull,
    );
    handle.dispose();
  });

  testWidgets('renders in light theme without overflow/error (a11y)', (
    tester,
  ) async {
    await pump(tester, b: Brightness.light);
    expect(tester.takeException(), isNull);
    expect(find.text('Hermes'), findsWidgets);
  });

  testWidgets('Agent management screen matches golden', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Hermes').first);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AgentManagementScreen),
      matchesGoldenFile('goldens/agent_screen.png'),
    );
  }, tags: 'golden');
}
