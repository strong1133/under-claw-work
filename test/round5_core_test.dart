import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory root;
  late Workspace workspace;

  setUp(() {
    root = Directory.systemTemp.createTempSync('worklog-round5-');
    workspace = Workspace(root)..ensureLayout();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('one OPR claim control and disposition contract survives rebuild', () {
    final task = _readyTask();
    TaskRepository(workspace).create(task);
    final projection = ProjectionStore(workspace);
    final runId = ControlService(
      workspace,
      projection,
    ).requestStart(task, 'OPR-contract');
    final request = CanonicalRepository(
      workspace,
    ).list(EntityKind.controlRequest).single;
    final claim = ClaimService(
      workspace,
      projection,
    ).acquire(taskId: task.id, runId: runId, environmentId: 'ENV-test');
    final disposition = ControlService(
      workspace,
      projection,
    ).addDisposition(request.id, 'accepted');

    final validator = WorklogContractValidator();
    validator.validateEntity(request);
    validator.validateEntity(claim);
    validator.validateEntity(disposition);
    projection.rebuild();
    expect(
      projection
          .open()
          .select('SELECT operation_id FROM runs')
          .single['operation_id'],
      'OPR-contract',
    );
    projection.dispose();
  });

  test(
    'completed orchestration proposes validated candidate for acceptance',
    () async {
      final canonical = CanonicalRepository(workspace);
      _entity(canonical, EntityKind.domain, 'DOM-test', {'name': 'Domain'});
      _entity(canonical, EntityKind.milestone, 'MLS-test', {
        'title': 'Milestone',
        'domain_id': 'DOM-test',
      });
      _entity(canonical, EntityKind.objective, 'OBJ-test', {
        'title': 'Objective',
        'scope': {'domain_id': 'DOM-test', 'milestone_id': 'MLS-test'},
      });
      _entity(canonical, EntityKind.knowledge, 'KNW-test', {
        'title': 'Evidence',
        'kind': 'confirmed_fact',
        'confidence': 'confirmed',
        'scope': {
          'domain_ids': ['DOM-test'],
        },
      });
      final parent = _readyTask(autoDeriveTasks: true);
      TaskRepository(workspace).create(parent);
      final projection = ProjectionStore(workspace);
      await SkillPipeline(
        projection,
        _CandidateRunner(),
      ).execute(parent, 'RUN-candidate');

      final candidates = TaskCandidateService(workspace);
      final pending = candidates.list().single;
      expect(pending.objectiveIds, ['OBJ-test']);
      expect(pending.knowledgeIds, ['KNW-test']);
      final accepted = candidates.accept(pending.id);
      expect(accepted.parentTaskId, parent.id);
      expect(accepted.approval, PromptApproval.missing);
      expect(accepted.createdAutomatically, isTrue);
      projection.dispose();
    },
  );

  test('projection store self-recovers corrupt SQLite through lifecycle', () {
    TaskRepository(workspace).create(_readyTask());
    final projection = ProjectionStore(workspace);
    projection.rebuild();
    projection.dispose();
    workspace.database.writeAsStringSync('not sqlite', flush: true);

    final recovered = ProjectionStore(workspace);
    expect(recovered.rebuild(), hasLength(1));
    expect(
      recovered.open().select('PRAGMA integrity_check').single.values.single,
      'ok',
    );
    recovered.dispose();
  });

  test('migration report sanitizes source root and preserves state', () {
    final source = Directory('${root.path}/private-source')..createSync();
    File('${source.path}/legacy.md').writeAsStringSync('''
[완료] <PT-demo>
**요구사항**
완료된 작업
''');
    final service = LegacyMigrationService(workspace);
    final plan = service.dryRun(source);
    final report = File(
      '${workspace.migrations.path}/${plan.importId}.json',
    ).readAsStringSync();
    expect(report, isNot(contains(source.absolute.path)));
    expect(jsonDecode(report)['source_locator'], 'private-source');
    final imported = service.import(
      plan,
      approved: true,
      domainId: 'DOM-test',
      milestoneId: 'MLS-test',
      targetEnvironment: 'ENV-test',
    );
    expect(imported.single.status, TaskStatus.completed);
    service.rollback(plan.importId);
    expect(TaskRepository(workspace).list(), isEmpty);
  });
}

class _CandidateRunner implements RunnerAdapter {
  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async => OrchestrationResult(
    trace: const [
      SkillInvocation('under-claw-meta-prompt', 'RUN-candidate', 0),
      SkillInvocation('under-claw-jarvis-plan-loop', 'RUN-candidate', 0),
      SkillInvocation(
        'under-claw-jarvis-plan',
        'RUN-candidate',
        1,
        parentSkillId: 'under-claw-jarvis-plan-loop',
      ),
    ],
    reviewerScore: 9.7,
    independentReviewer: true,
    evidence: RunnerEvidence.fixture('candidate-runner'),
    candidateProposals: const [
      CandidateProposal(
        title: 'Follow up',
        draft: 'Perform the evidenced follow-up.',
        objectiveIds: ['OBJ-test'],
        knowledgeIds: ['KNW-test'],
        referenceIds: [],
        reason: 'Reviewer identified remaining objective work.',
      ),
    ],
  );
}

CanonicalEntity _entity(
  CanonicalRepository repository,
  EntityKind kind,
  String id,
  Map<String, Object?> fields,
) => repository.create(
  CanonicalEntity(
    kind: kind,
    id: id,
    data: {
      'schema_version': 1,
      'id': id,
      'type': kind.type,
      'status': 'active',
      ...fields,
    },
  ),
);

WorkTask _readyTask({bool autoDeriveTasks = false}) => WorkTask(
  id: 'TSK-contract',
  domainId: 'DOM-test',
  milestoneId: 'MLS-test',
  title: 'Contract Task',
  status: TaskStatus.ready,
  promptDraft: 'Draft',
  promptMeta: 'Meta',
  promptDraftRevision: 1,
  promptMetaSourceRevision: 1,
  promptMetaSourceSha256: TaskRepository.draftSha256('Draft'),
  approval: PromptApproval.approved,
  autoDeriveTasks: autoDeriveTasks,
  targetEnvironment: 'ENV-test',
);
