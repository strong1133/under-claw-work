import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:under_claw_work/core/worklog_core.dart';
import 'package:under_claw_work/main.dart';

void main() {
  testWidgets('empty workspace renders native desktop shell', (tester) async {
    final temporary = Directory.systemTemp.createTempSync('under-claw-widget-');
    addTearDown(() => temporary.deleteSync(recursive: true));

    await tester.pumpWidget(UnderClawWorkApp(workspaceOverride: temporary));
    await tester.pumpAndSettle();

    // The workspace identity shows in both the navigation rail header and the
    // persistent status bar (the Warp/Orca-style bottom chrome).
    expect(find.text('Under Claw Work'), findsNWidgets(2));
    expect(find.text('No tasks yet'), findsOneWidget);
  });

  testWidgets('GUI creates and displays a Domain through Core', (tester) async {
    final temporary = Directory.systemTemp.createTempSync('under-claw-widget-');
    addTearDown(() => temporary.deleteSync(recursive: true));

    await tester.pumpWidget(UnderClawWorkApp(workspaceOverride: temporary));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-area-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('domain').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Product Domain',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Description / AI context'),
      'Durable shared context',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Product Domain'), findsWidgets);
    expect(find.text('Durable shared context'), findsOneWidget);
  });

  testWidgets('GUI shows pending control and supports withdrawal', (
    tester,
  ) async {
    final temporary = Directory.systemTemp.createTempSync('under-claw-widget-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final workspace = Workspace(temporary)..ensureLayout();
    TaskRepository(workspace).create(
      const WorkTask(
        id: 'TSK-widget',
        domainId: 'DOM-example',
        milestoneId: 'MLS-example',
        title: 'Controllable task',
        status: TaskStatus.ready,
        promptDraft: 'Draft',
        promptMeta: 'Meta',
        promptDraftRevision: 1,
        promptMetaSourceRevision: 1,
        approval: PromptApproval.approved,
        autoDeriveTasks: false,
        targetEnvironment: 'ENV-local',
      ),
    );

    await tester.pumpWidget(UnderClawWorkApp(workspaceOverride: temporary));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Request start'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request start'));
    await tester.pumpAndSettle();

    expect(find.text('start · pending'), findsOneWidget);
    await tester.ensureVisible(find.text('Withdraw request'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Withdraw request'));
    await tester.pumpAndSettle();

    expect(find.text('start · withdrawn'), findsOneWidget);
    expect(
      CanonicalRepository(
        workspace,
      ).list(EntityKind.controlDisposition).single.data['disposition'],
      'withdrawn',
    );
  });
}
