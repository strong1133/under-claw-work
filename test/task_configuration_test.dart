import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late EntityService entities;
  late ScopeConfigurationService configurations;
  late EnvironmentRecord macbook;
  late EnvironmentRecord astroHermes;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync(
      'under-claw-task-configuration-',
    );
    workspace = Workspace(temporary)..ensureLayout();
    entities = EntityService(workspace);
    configurations = ScopeConfigurationService(workspace);
    final environments = EnvironmentService(workspace);
    macbook = environments.register(
      identity: const EnvironmentIdentity(
        machineKey: 'MK-macbook',
        os: 'macos',
        architecture: 'arm64',
      ),
      alias: 'MacBook',
    );
    astroHermes = environments.register(
      identity: const EnvironmentIdentity(
        machineKey: 'MK-astrohermes',
        os: 'linux',
        architecture: 'x64',
      ),
      alias: 'astro-hermes',
      kind: 'agent_runtime',
    );
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test(
    'Task round-trips optional scope and multiple project environment model relations',
    () {
      final domain = entities.create(kind: EntityKind.domain, title: 'AI');
      final projectOne = configurations.createProject(
        title: 'Under Claw',
        domainId: domain.id,
      );
      final projectTwo = configurations.createProject(
        title: 'Workspace',
        domainId: domain.id,
      );
      final repository = TaskRepository(workspace);
      repository.create(
        WorkTask(
          id: 'TSK-related',
          title: 'Related',
          status: TaskStatus.writing,
          promptDraft: 'Related draft',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
        ),
      );

      repository.create(
        WorkTask(
          id: 'TSK-portable',
          title: 'Portable Task',
          status: TaskStatus.writing,
          promptDraft: 'Draft',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          processingMode: TaskProcessingMode.manual,
          autoDeriveTasks: true,
          autoFollowupTasks: true,
          autoAcceptGeneratedTasks: false,
          projectIds: [projectOne.id, projectTwo.id],
          targetEnvironmentIds: [macbook.id, astroHermes.id],
          modelSelectionKeys: const ['primary', 'reviewer'],
          relatedTaskIds: const ['TSK-related'],
        ),
      );

      final loaded = repository.get('TSK-portable')!;
      expect(loaded.hasDomain, isFalse);
      expect(loaded.hasMilestone, isFalse);
      expect(loaded.projectIds, [projectOne.id, projectTwo.id]);
      expect(loaded.targetEnvironmentIds, [macbook.id, astroHermes.id]);
      expect(loaded.modelSelectionKeys, ['primary', 'reviewer']);
      expect(loaded.relatedTaskIds, ['TSK-related']);
      expect(loaded.processingMode, TaskProcessingMode.manual);
      expect(TaskCodec.encode(loaded), contains('schema_version: 3'));
    },
  );

  test('Milestone requires Domain but Domain does not require Milestone', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'MVP',
      domainId: domain.id,
    );
    final repository = TaskRepository(workspace);

    repository.create(_task(id: 'TSK-domain-only', domainId: domain.id));
    expect(repository.get('TSK-domain-only')!.hasMilestone, isFalse);

    expect(
      () => repository.create(
        _task(id: 'TSK-invalid-scope', milestoneId: milestone.id),
      ),
      throwsA(isA<ContractViolation>()),
    );
  });

  test('status gates Meta request, automatic generation, and approval', () {
    final repository = TaskRepository(workspace);
    final manual = repository.create(_task(id: 'TSK-status'));

    expect(AutoMetaWorker.isEligible(manual), isFalse);
    final requested = repository.requestMeta(manual);
    expect(requested.status, TaskStatus.metaRequested);
    expect(AutoMetaWorker.isEligible(requested), isFalse);

    final automatic = repository.update(
      requested.copyWith(processingMode: TaskProcessingMode.automatic),
    );
    expect(AutoMetaWorker.isEligible(automatic), isTrue);

    final generated = repository.saveMeta(automatic, 'Meta');
    expect(generated.status, TaskStatus.metaReview);
    expect(AutoMetaWorker.isEligible(generated), isFalse);

    final approved = repository.approveMeta(generated);
    expect(approved.status, TaskStatus.ready);
    expect(approved.isExecutionEligible, isTrue);
  });

  test(
    'start targets one allowed environment and resolves local model keys',
    () {
      final domain = entities.create(kind: EntityKind.domain, title: 'AI');
      HostBindingRegistry(workspace).set(
        HostScopeBinding(
          environmentId: astroHermes.id,
          domainId: domain.id,
          modelBindings: const {
            'primary': 'provider-a/reasoning-model',
            'reviewer': 'provider-b/review-model',
          },
        ),
      );
      final task = TaskRepository(workspace).create(
        _readyTask(
          id: 'TSK-models',
          domainId: domain.id,
          targetEnvironmentIds: [macbook.id, astroHermes.id],
          modelSelectionKeys: const ['primary', 'reviewer'],
        ),
      );
      final projection = ProjectionStore(workspace)..rebuild();
      addTearDown(projection.dispose);

      ControlService(
        workspace,
        projection,
      ).requestStart(task, 'OPR-models', targetEnvironmentId: astroHermes.id);
      final request = CanonicalRepository(
        workspace,
      ).list(EntityKind.controlRequest).single;
      expect(request.data['target_environment_id'], astroHermes.id);
      expect(request.data['model_selection_keys'], ['primary', 'reviewer']);

      expect(
        () => ControlService(workspace, projection).requestStart(
          task,
          'OPR-wrong-environment',
          targetEnvironmentId: 'ENV-not-selected',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'automatic ready Task schedules once; manual and writing Tasks do not',
    () {
      final automatic = TaskRepository(workspace).create(
        _readyTask(
          id: 'TSK-automatic',
          processingMode: TaskProcessingMode.automatic,
          targetEnvironmentIds: [astroHermes.id],
        ),
      );
      TaskRepository(workspace).create(
        _readyTask(
          id: 'TSK-manual',
          processingMode: TaskProcessingMode.manual,
          targetEnvironmentIds: [astroHermes.id],
        ),
      );
      TaskRepository(workspace).create(
        _task(
          id: 'TSK-writing',
          processingMode: TaskProcessingMode.automatic,
          targetEnvironmentIds: [astroHermes.id],
        ),
      );
      final projection = ProjectionStore(workspace)..rebuild();
      addTearDown(projection.dispose);
      final automation = TaskAutomationService(workspace, projection);

      final first = automation.runNext();
      expect(first?.taskId, automatic.id);
      expect(first?.targetEnvironmentId, astroHermes.id);
      expect(automation.runNext(), isNull);
      final requests = CanonicalRepository(workspace)
          .list(EntityKind.controlRequest)
          .where((item) => item.data['command'] == 'start');
      expect(requests, hasLength(1));
    },
  );

  test(
    'child and related candidates inherit portable execution selections',
    () {
      final parent = TaskRepository(workspace).create(
        _readyTask(
          id: 'TSK-parent',
          processingMode: TaskProcessingMode.automatic,
          targetEnvironmentIds: [macbook.id, astroHermes.id],
          modelSelectionKeys: const ['primary'],
        ).copyWith(
          autoDeriveTasks: true,
          autoFollowupTasks: true,
          autoAcceptGeneratedTasks: true,
          maxGenerationDepth: 2,
        ),
      );
      final candidates = TaskCandidateService(workspace);
      final childCandidate = candidates.propose(
        parentTaskId: parent.id,
        title: 'Child',
        draft: 'Child draft',
        objectiveIds: const [],
        knowledgeIds: const [],
        referenceIds: const [],
        reason: 'Break down the parent.',
      );
      final child = candidates.accept(childCandidate.id);
      expect(child.parentTaskId, parent.id);
      expect(child.relatedTaskIds, isEmpty);
      expect(child.status, TaskStatus.metaRequested);
      expect(child.processingMode, TaskProcessingMode.automatic);
      expect(child.effectiveTargetEnvironmentIds, [macbook.id, astroHermes.id]);
      expect(child.modelSelectionKeys, ['primary']);

      final relatedCandidate = candidates.propose(
        parentTaskId: parent.id,
        title: 'Related',
        draft: 'Related draft',
        objectiveIds: const [],
        knowledgeIds: const [],
        referenceIds: const [],
        reason: 'Track adjacent work.',
        relation: GeneratedTaskRelation.related,
      );
      final related = candidates.accept(relatedCandidate.id);
      expect(related.parentTaskId, isNull);
      expect(related.relatedTaskIds, [parent.id]);
    },
  );

  test('terminal Tasks reject Prompt mutation', () {
    final repository = TaskRepository(workspace);
    final completed = repository.create(
      _readyTask(id: 'TSK-completed').copyWith(status: TaskStatus.completed),
    );

    expect(() => repository.saveDraft(completed, 'Changed'), throwsStateError);
    expect(
      () => repository.saveMeta(completed, 'Changed Meta'),
      throwsStateError,
    );
    expect(() => repository.approveMeta(completed), throwsStateError);
  });

  test('configuration preserves legacy ids and codec rejects mixed lists', () {
    final repository = TaskRepository(workspace);
    final task = repository.create(
      _task(
        id: 'TSK-legacy-configuration',
      ).copyWith(legacyIds: const ['legacy-task-id']),
    );
    final configured = repository.configure(
      task,
      title: task.title,
      domainId: '',
      milestoneId: '',
      projectIds: const [],
      targetEnvironmentIds: const [],
      modelSelectionKeys: const [],
      processingMode: TaskProcessingMode.manual,
      autoDeriveTasks: false,
      autoFollowupTasks: false,
      autoAcceptGeneratedTasks: false,
      maxGenerationDepth: 2,
      parentTaskId: null,
      relatedTaskIds: const [],
    );

    expect(configured.legacyIds, ['legacy-task-id']);
    expect(
      () => TaskCodec.decode('''
schema_version: 3
id: TSK-malformed-list
title: malformed
status: writing
target_environment_ids: [ENV-valid, 7]
prompt:
  draft_revision: 1
'''),
      throwsFormatException,
    );
  });

  test('candidate acceptance rechecks the current parent policy', () {
    final repository = TaskRepository(workspace);
    final parent = repository.create(
      _task(id: 'TSK-policy-parent').copyWith(autoDeriveTasks: true),
    );
    final candidates = TaskCandidateService(workspace);
    final candidate = candidates.propose(
      parentTaskId: parent.id,
      title: 'Child',
      draft: 'Draft',
      objectiveIds: const [],
      knowledgeIds: const [],
      referenceIds: const [],
      reason: 'Policy probe.',
    );
    repository.update(parent.copyWith(autoDeriveTasks: false));

    expect(() => candidates.accept(candidate.id), throwsStateError);
  });
}

WorkTask _task({
  required String id,
  String domainId = '',
  String milestoneId = '',
  TaskProcessingMode processingMode = TaskProcessingMode.manual,
  List<String> targetEnvironmentIds = const [],
}) => WorkTask(
  id: id,
  domainId: domainId,
  milestoneId: milestoneId,
  title: id,
  status: TaskStatus.writing,
  promptDraft: 'Draft',
  promptMeta: '',
  promptDraftRevision: 1,
  promptMetaSourceRevision: 0,
  approval: PromptApproval.missing,
  processingMode: processingMode,
  autoDeriveTasks: false,
  targetEnvironmentIds: targetEnvironmentIds,
);

WorkTask _readyTask({
  required String id,
  String domainId = '',
  TaskProcessingMode processingMode = TaskProcessingMode.manual,
  List<String> targetEnvironmentIds = const [],
  List<String> modelSelectionKeys = const [],
}) => WorkTask(
  id: id,
  domainId: domainId,
  title: id,
  status: TaskStatus.ready,
  promptDraft: 'Draft',
  promptMeta: 'Meta',
  promptDraftRevision: 1,
  promptMetaSourceRevision: 1,
  promptMetaSourceSha256: TaskRepository.draftSha256('Draft'),
  approval: PromptApproval.approved,
  processingMode: processingMode,
  autoDeriveTasks: false,
  targetEnvironmentIds: targetEnvironmentIds,
  modelSelectionKeys: modelSelectionKeys,
);
