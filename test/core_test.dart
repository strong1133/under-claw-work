import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late ProjectionStore projection;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-work-');
    workspace = Workspace(temporary);
    workspace.ensureLayout();
    projection = ProjectionStore(workspace);
  });

  tearDown(() {
    projection.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('deleted SQLite projection rebuilds from YAML source of truth', () {
    _writeTask(workspace, _approvedTaskYaml);
    expect(projection.rebuild(), hasLength(1));
    projection.dispose();
    workspace.database.deleteSync();
    projection = ProjectionStore(workspace);
    expect(projection.rebuild().single.id, 'TSK-example');
    expect(workspace.database.existsSync(), isTrue);
  });

  test('stale Meta Prompt blocks start', () {
    _writeTask(
      workspace,
      _approvedTaskYaml.replaceFirst(
        'meta_source_revision: 2',
        'meta_source_revision: 1',
      ),
    );
    final task = projection.rebuild().single;
    expect(
      () => ControlService(workspace, projection).requestStart(task, 'OP-1'),
      throwsStateError,
    );
  });

  test('operation id is idempotent and creates one run', () {
    _writeTask(workspace, _approvedTaskYaml);
    final task = projection.rebuild().single;
    final service = ControlService(workspace, projection);
    final first = service.requestStart(task, 'OPR-repeat');
    final recovered = service.requestStart(task, 'OPR-repeat');
    expect(recovered, first);
    expect(
      projection.open().select('SELECT id FROM runs WHERE operation_id = ?', [
        'OPR-repeat',
      ]),
      hasLength(1),
    );
  });

  test('control disposition is immutable', () {
    _writeTask(workspace, _approvedTaskYaml);
    final task = projection.rebuild().single;
    final service = ControlService(workspace, projection);
    service.requestStart(task, 'OPR-disposition');
    final request = CanonicalRepository(
      workspace,
    ).list(EntityKind.controlRequest).single;
    service.addDisposition(request.id, 'accepted');
    expect(
      () => service.addDisposition(request.id, 'rejected'),
      throwsFormatException,
    );
  });

  test(
    'orchestration skill validates and audits nested required order',
    () async {
      _writeTask(workspace, _approvedTaskYaml);
      final task = projection.rebuild().single;
      final runner = _RecordingRunner();
      await SkillPipeline(projection, runner).execute(task, 'RUN-example');
      expect(runner.calls, [SkillPipeline.orchestrator]);
      expect(runner.trace.map((item) => item.skillId), [
        SkillPipeline.metaPrompt,
        SkillPipeline.planLoop,
        SkillPipeline.basePlan,
        SkillPipeline.basePlan,
      ]);
      final rows = projection.open().select(
        'SELECT skill_id FROM skill_invocations ORDER BY sequence',
      );
      expect(rows.map((row) => row['skill_id']), [
        SkillPipeline.orchestrator,
        ...runner.trace.map((item) => item.skillId),
      ]);
    },
  );

  test('review score below TARGET 9.5 blocks completion', () async {
    _writeTask(workspace, _approvedTaskYaml);
    final task = projection.rebuild().single;
    final runner = _RecordingRunner(score: 9.4);
    expect(
      SkillPipeline(projection, runner).execute(task, 'RUN-score'),
      throwsStateError,
    );
  });

  test('missing base plan round blocks completion', () async {
    _writeTask(workspace, _approvedTaskYaml);
    final task = projection.rebuild().single;
    final runner = _RecordingRunner(
      trace: [
        const SkillInvocation(SkillPipeline.metaPrompt, 'RUN-round', 0),
        const SkillInvocation(SkillPipeline.planLoop, 'RUN-round', 0),
        const SkillInvocation(SkillPipeline.basePlan, 'RUN-round', 1),
        const SkillInvocation(SkillPipeline.basePlan, 'RUN-round', 3),
      ],
    );
    expect(
      SkillPipeline(projection, runner).execute(task, 'RUN-round'),
      throwsStateError,
    );
  });

  test('authentication stays locked while provider is pending', () async {
    final gate = RepositoryAuthGate();
    expect(gate.canAcceptPassword, isFalse);
    await expectLater(
      gate.unlock(
        const AuthContext(
          repositoryId: 'repo-example',
          policyVersion: 1,
          environmentId: 'ENV-example',
        ),
        'example-only',
      ),
      throwsA(isA<AuthUnavailable>()),
    );
  });
}

void _writeTask(Workspace workspace, String content) {
  File(
    p.join(workspace.tasks.path, 'TSK-example.yaml'),
  ).writeAsStringSync(content);
}

const _approvedTaskYaml = '''
schema_version: 1
id: TSK-example
domain_id: DOM-example
milestone_id: MLS-example
title: "Example task"
status: ready
auto_derive_tasks: true
target_environment: "ENV-local"
prompt:
  draft_revision: 2
  meta_source_revision: 2
  approval: approved
  draft: |-
    Create a deterministic example.
  meta: |-
    Execute the approved example with verification.
''';

class _RecordingRunner implements RunnerAdapter {
  _RecordingRunner({this.score = 9.5, List<SkillInvocation>? trace})
    : trace =
          trace ??
          const [
            SkillInvocation(SkillPipeline.metaPrompt, 'RUN-example', 0),
            SkillInvocation(SkillPipeline.planLoop, 'RUN-example', 0),
            SkillInvocation(SkillPipeline.basePlan, 'RUN-example', 1),
            SkillInvocation(SkillPipeline.basePlan, 'RUN-example', 2),
          ];

  final double score;
  final List<SkillInvocation> trace;
  final List<String> calls = [];

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    calls.add(invocation.skillId);
    return OrchestrationResult(
      trace: trace,
      reviewerScore: score,
      independentReviewer: true,
      evidence: RunnerEvidence.fixture('core-runner'),
      knowledgeIds: const ['KNW-example'],
      eventIds: const ['EVT-example'],
    );
  }
}
