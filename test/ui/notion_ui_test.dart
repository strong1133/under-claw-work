import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/ui/app_theme.dart';
import 'package:under_claw_work/ui/notion_screens.dart';
import 'package:under_claw_work/ui/notion_sync_port.dart';
import 'package:under_claw_work/ui/workspace_shell.dart';

class _FakeNotionController implements NotionUiController {
  final notifier = ValueNotifier(const NotionSyncViewState());

  @override
  ValueListenable<NotionSyncViewState> get state => notifier;

  NotionConnectionDraft? connection;
  var syncCount = 0;
  final resolutions = <(String, NotionConflictChoice)>[];

  @override
  Future<void> connect(NotionConnectionDraft draft) async {
    connection = draft;
    notifier.value = const NotionSyncViewState(
      status: NotionConnectionStatus.connected,
      message: 'Connected.',
    );
  }

  @override
  Future<void> syncNow() async {
    syncCount++;
  }

  @override
  Future<void> resolveConflict(
    String conflictId,
    NotionConflictChoice choice,
  ) async {
    resolutions.add((conflictId, choice));
  }
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(body: SizedBox(width: 1200, height: 800, child: child)),
);

void main() {
  test('theme fixes every Material text role to D2Coding 16pt', () {
    final theme = AppTheme.dark();
    for (final style in [
      theme.textTheme.displayLarge,
      theme.textTheme.displayMedium,
      theme.textTheme.displaySmall,
      theme.textTheme.headlineLarge,
      theme.textTheme.headlineMedium,
      theme.textTheme.headlineSmall,
      theme.textTheme.titleLarge,
      theme.textTheme.titleMedium,
      theme.textTheme.titleSmall,
      theme.textTheme.bodyLarge,
      theme.textTheme.bodyMedium,
      theme.textTheme.bodySmall,
      theme.textTheme.labelLarge,
      theme.textTheme.labelMedium,
      theme.textTheme.labelSmall,
    ].whereType<TextStyle>()) {
      expect(style.fontFamily, 'D2Coding');
      expect(style.fontSize, 16);
    }
  });

  testWidgets('unified shell switches dense workspace destinations', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const UnifiedWorkspaceShell(
          destinations: [
            WorkspaceDestination(
              label: 'Tasks',
              icon: Icons.task_alt,
              child: Text('Task surface'),
            ),
            WorkspaceDestination(
              label: 'Notion',
              icon: Icons.sync,
              child: Text('Notion surface'),
            ),
          ],
        ),
      ),
    );

    expect(find.byKey(const Key('workspace-rail')), findsOneWidget);
    expect(find.text('Task surface'), findsOneWidget);
    await tester.tap(find.byKey(const Key('workspace-destination-1')));
    await tester.pump();
    expect(find.text('Notion surface'), findsOneWidget);
  });

  testWidgets('Notion setup passes token once then clears the field', (
    tester,
  ) async {
    final controller = _FakeNotionController();
    await tester.pumpWidget(_app(NotionSetupView(controller: controller)));

    await tester.enterText(
      find.byKey(const Key('notion-token')),
      'test-placeholder-token',
    );
    await tester.enterText(
      find.byKey(const Key('notion-db-domain')),
      'db-domain',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('notion-db-objective')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const Key('notion-db-objective')),
      'db-objective',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('notion-connect')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('notion-connect')));
    await tester.pump();

    expect(controller.connection?.token, 'test-placeholder-token');
    expect(controller.connection?.databaseIds['domain'], 'db-domain');
    expect(controller.connection?.databaseIds['objective'], 'db-objective');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('notion-token')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets(
    'conflict view renders real differences and protects authoritative fields',
    (tester) async {
      final controller = _FakeNotionController();
      controller.notifier.value = const NotionSyncViewState(
        status: NotionConnectionStatus.connected,
        conflicts: [
          NotionConflictView(
            conflictId: 'ENV-one@r2',
            canonicalId: 'ENV-one',
            type: 'environment',
            remoteRevision: 'r2',
            gitProperties: {'title': 'Local Mac', 'machine_key': 'MK-git'},
            notionProperties: {
              'title': 'Studio Mac',
              'machine_key': 'MK-notion',
            },
            authoritativeFields: {'machine_key'},
          ),
        ],
      );
      await tester.pumpWidget(
        _app(NotionConflictViewScreen(controller: controller)),
      );

      final apply = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Apply Notion'),
      );
      expect(apply.onPressed, isNull);
      expect(find.text('Git: Local Mac'), findsOneWidget);
      expect(find.text('Notion: Studio Mac'), findsOneWidget);
      expect(
        find.text('Git authoritative · Notion cannot apply this field.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Keep Git'));
      expect(controller.resolutions, [
        ('ENV-one@r2', NotionConflictChoice.keepGit),
      ]);
    },
  );

  testWidgets('postpone targets one conflict and keeps its snapshot visible', (
    tester,
  ) async {
    final controller = _FakeNotionController();
    controller.notifier.value = const NotionSyncViewState(
      status: NotionConnectionStatus.error,
      conflicts: [
        NotionConflictView(
          conflictId: 'DOM-one@r3',
          canonicalId: 'DOM-one',
          type: 'domain',
          remoteRevision: 'r3',
          gitProperties: {'title': 'Git title'},
          notionProperties: {'title': 'Notion title'},
        ),
        NotionConflictView(
          conflictId: 'DOM-two@r4',
          canonicalId: 'DOM-two',
          type: 'domain',
          remoteRevision: 'r4',
          gitProperties: {'title': 'Second Git title'},
          notionProperties: {'title': 'Second Notion title'},
        ),
      ],
    );
    await tester.pumpWidget(
      _app(NotionConflictViewScreen(controller: controller)),
    );

    final firstCard = find.byKey(const Key('notion-conflict-DOM-one@r3'));
    await tester.tap(
      find.descendant(of: firstCard, matching: find.text('Postpone')),
    );

    expect(controller.resolutions, [
      ('DOM-one@r3', NotionConflictChoice.postpone),
    ]);
    expect(find.byType(Card), findsNWidgets(2));
  });
}
