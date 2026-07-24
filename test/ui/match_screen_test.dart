import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';
import 'package:under_claw_work/ui/match_screen.dart';
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
        home: MatchReviewScreen(workspaceRoot: root),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists proposed match from MatchService with StatusPill', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('KNW-fact → MLS-mgmt'), findsWidgets);
    expect(find.byType(StatusPill), findsWidgets);
    expect(find.text('proposed'), findsWidgets);
  });

  testWidgets('approve transitions state and appends immutable audit history', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('KNW-fact → MLS-mgmt').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();
    final match = MatchService(Workspace(root)).get('MAT-review')!;
    expect(match.reviewState, 'approved');
    // History is append-only: the proposed entry is preserved.
    expect(match.history.length, greaterThanOrEqualTo(2));
  });

  testWidgets('reject is disabled once a match is no longer proposed (a11y)', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('KNW-fact → MLS-mgmt').first);
    await tester.pumpAndSettle();
    // Approve first, then Reject must be disabled (illegal transition guarded).
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();
    final reject = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Reject'),
    );
    expect(reject.onPressed, isNull);
  });

  testWidgets('renders in light theme without error (a11y)', (tester) async {
    await pump(tester, b: Brightness.light);
    expect(tester.takeException(), isNull);
    expect(find.text('proposed'), findsWidgets);
  });

  testWidgets('New match dialog proposes a manual user match (requirement 2)', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New match'));
    await tester.pumpAndSettle();
    // The dialog picks the first Knowledge subject and first target by default.
    await tester.tap(find.widgetWithText(FilledButton, 'Propose'));
    await tester.pumpAndSettle();
    final manual = MatchService(Workspace(root))
        .list()
        .where((m) => m.matchMode == 'manual' && m.id != 'MAT-review')
        .toList();
    expect(manual, isNotEmpty, reason: 'a new manual proposal was created');
    expect(manual.first.reviewState, 'proposed');
    expect(manual.first.subjectId, 'KNW-fact');
    expect(manual.first.targetId, 'DOM-mgmt');
  });

  testWidgets('Auto-match proposes reviewable agent matches (requirement 2)', (
    tester,
  ) async {
    // Seed a subject/target that share salient label terms.
    final entities = EntityService(Workspace(root));
    final domain = entities.create(
      kind: EntityKind.domain,
      title: 'Portal onboarding',
    );
    entities.create(
      kind: EntityKind.knowledge,
      title: 'Portal onboarding notes',
      body: 'Portal steps.',
      domainId: domain.id,
    );
    await pump(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Auto-match'));
    await tester.pumpAndSettle();
    final agentMatches = MatchService(
      Workspace(root),
    ).list().where((m) => m.matchMode == 'agent').toList();
    expect(agentMatches, isNotEmpty);
    // Agent matches are never auto-approved from the screen: still reviewable.
    expect(agentMatches.every((m) => m.reviewState == 'proposed'), isTrue);
    expect(agentMatches.any((m) => m.targetId == domain.id), isTrue);
  });

  testWidgets('manual and agent matches coexist with reviewable provenance', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'New match'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Propose'));
    await tester.pumpAndSettle();

    final entities = EntityService(Workspace(root));
    final domain = entities.create(
      kind: EntityKind.domain,
      title: 'Ledger reconciliation',
    );
    entities.create(
      kind: EntityKind.knowledge,
      title: 'Ledger reconciliation guide',
      body: 'Shared-term fixture for deterministic matching.',
      domainId: domain.id,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Auto-match'));
    await tester.pumpAndSettle();

    final reloaded = MatchService(Workspace(root)).list();
    final manual = reloaded.singleWhere(
      (match) =>
          match.matchMode == 'manual' &&
          match.id != 'MAT-review' &&
          match.actorId == 'user:operator',
    );
    final agent = reloaded.singleWhere(
      (match) =>
          match.matchMode == 'agent' &&
          match.targetId == domain.id &&
          match.actorId == 'agent:auto-match',
    );

    expect(manual.id, isNot(agent.id));
    expect(manual.reviewState, 'proposed');
    expect(agent.reviewState, 'proposed');
    expect(manual.history, isNotEmpty);
    expect(agent.history, isNotEmpty);
    expect(agent.evidence.toLowerCase(), contains('ledger'));
    expect(agent.confidence, isNotNull);
  });

  testWidgets('Match review screen matches golden', (tester) async {
    await pump(tester);
    await tester.tap(find.text('KNW-fact → MLS-mgmt').first);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MatchReviewScreen),
      matchesGoldenFile('goldens/match_screen.png'),
    );
  }, tags: 'golden');
}
