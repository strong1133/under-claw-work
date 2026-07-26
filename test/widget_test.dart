import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:under_claw_work/core/worklog_core.dart';
import 'package:under_claw_work/main.dart';
import 'package:under_claw_work/ui/task_configuration_dialog.dart';

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

  testWidgets('Knowledge scope is selected, never typed as a raw id', (
    tester,
  ) async {
    final temporary = Directory.systemTemp.createTempSync('under-claw-widget-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final workspace = Workspace(temporary)..ensureLayout();
    final entities = EntityService(workspace);
    final domain = entities.create(kind: EntityKind.domain, title: 'Product');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'MVP',
      domainId: domain.id,
    );
    // A Milestone in a different Domain must not be offered once Product is
    // selected.
    final other = entities.create(kind: EntityKind.domain, title: 'Other');
    entities.create(
      kind: EntityKind.milestone,
      title: 'Unrelated',
      domainId: other.id,
    );

    await tester.pumpWidget(UnderClawWorkApp(workspaceOverride: temporary));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-area-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('knowledge').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // No free-text id fields survive.
    expect(find.widgetWithText(TextField, 'Domain ID'), findsNothing);
    expect(
      find.widgetWithText(TextField, 'Milestone ID (optional)'),
      findsNothing,
    );
    expect(find.byKey(const Key('entity-domain')), findsOneWidget);
    expect(find.byKey(const Key('entity-task')), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Recall rule',
    );
    await tester.tap(find.byKey(const Key('entity-domain')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Product · ${domain.id}').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('entity-milestone')));
    await tester.pumpAndSettle();
    expect(find.text('Unrelated · '), findsNothing);
    await tester.tap(find.text('MVP · ${milestone.id}').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final created = CanonicalRepository(
      workspace,
    ).list(EntityKind.knowledge).single;
    expect((created.data['scope'] as Map)['domain_id'], domain.id);
    expect((created.data['scope'] as Map)['milestone_id'], milestone.id);
  });

  testWidgets('GUI exposes canonical sync and verified Meta generation', (
    tester,
  ) async {
    final temporary = Directory.systemTemp.createTempSync('under-claw-widget-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final workspace = Workspace(temporary)..ensureLayout();
    TaskRepository(workspace).create(
      const WorkTask(
        id: 'TSK-runtime-ui',
        domainId: 'DOM-example',
        milestoneId: 'MLS-example',
        title: 'Runtime task',
        status: TaskStatus.draft,
        promptDraft: 'Draft',
        promptMeta: '',
        promptDraftRevision: 1,
        promptMetaSourceRevision: 0,
        approval: PromptApproval.missing,
        autoDeriveTasks: false,
        targetEnvironment: 'ENV-local',
      ),
    );

    await tester.pumpWidget(UnderClawWorkApp(workspaceOverride: temporary));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('git-sync-now')), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('generate-meta')), findsOneWidget);
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
        promptMetaSourceSha256:
            'ebf12ef47cf575b3ba9a3cc019c5310146fdac88f6d1be6618d6e91158c2f174',
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
    expect(find.textContaining('pipeline pending'), findsOneWidget);
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

  testWidgets(
    'Task dialog creates unscoped automatic Task with multiple env and model selections',
    (tester) async {
      final temporary = Directory.systemTemp.createTempSync(
        'under-claw-widget-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final workspace = Workspace(temporary)..ensureLayout();
      final environments = EnvironmentService(workspace);
      final macbook = environments.register(
        identity: const EnvironmentIdentity(
          machineKey: 'MK-widgetmacbook',
          os: 'macos',
          architecture: 'arm64',
        ),
        alias: 'MacBook',
        kind: 'desktop',
        capabilities: const ['git'],
      );
      final astro = environments.register(
        identity: const EnvironmentIdentity(
          machineKey: 'MK-widgetastro',
          os: 'linux',
          architecture: 'x64',
        ),
        alias: 'astro-hermes',
        kind: 'agent_runtime',
        capabilities: const ['git'],
      );
      final bindings = HostBindingRegistry(workspace);
      for (final environment in [macbook, astro]) {
        bindings.set(
          HostScopeBinding(
            environmentId: environment.id,
            domainId: '',
            modelBindings: const {
              'primary': 'provider/primary-model',
              'reviewer': 'provider/reviewer-model',
            },
          ),
        );
      }

      TaskConfigurationDraft? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<TaskConfigurationDraft>(
                    context: context,
                    builder: (context) =>
                        TaskConfigurationDialog(workspace: workspace),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('task-title')),
        'Portable task',
      );
      await tester.enterText(
        find.byKey(const Key('task-draft')),
        'Draft prompt',
      );

      await tester.tap(find.text('Execution Environments (0)'));
      await tester.pumpAndSettle();
      final dialogList = find.byType(Scrollable).last;
      final macbookOption = find.textContaining('MacBook ·');
      await tester.scrollUntilVisible(
        macbookOption,
        80,
        scrollable: dialogList,
      );
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'MacBook · ${macbook.id}'),
          )
          .onChanged!(true);
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'astro-hermes · ${astro.id}'),
          )
          .onChanged!(true);
      await tester.pumpAndSettle();

      final modelHeader = find.text('Portable model selections (0)');
      await tester.scrollUntilVisible(modelHeader, 80, scrollable: dialogList);
      await tester.tap(modelHeader);
      await tester.pumpAndSettle();
      final primary = find.text('primary');
      await tester.scrollUntilVisible(primary, 80, scrollable: dialogList);
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'primary'),
          )
          .onChanged!(true);
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'reviewer'),
          )
          .onChanged!(true);
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('task-processing-mode')),
        100,
        scrollable: dialogList,
      );
      tester
          .widget<DropdownButtonFormField<TaskProcessingMode>>(
            find.byKey(const Key('task-processing-mode')),
          )
          .onChanged!(TaskProcessingMode.automatic);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('task-request-meta')),
        100,
        scrollable: dialogList,
      );
      tester
          .widget<SwitchListTile>(find.byKey(const Key('task-request-meta')))
          .onChanged!(true);
      tester
          .widget<FilledButton>(
            find.byKey(const Key('save-task-configuration')),
          )
          .onPressed!();
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.domainId, isEmpty);
      expect(result!.milestoneId, isEmpty);
      expect(result!.environmentIds, [astro.id, macbook.id]..sort());
      expect(result!.modelSelectionKeys, ['primary', 'reviewer']);
      expect(result!.processingMode, TaskProcessingMode.automatic);
      expect(result!.requestMeta, isTrue);
    },
  );
}
