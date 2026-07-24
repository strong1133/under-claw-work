import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory root;
  late Workspace workspace;
  late ProjectionStore projection;

  setUp(() {
    root = Directory.systemTemp.createTempSync('worklog-worker-');
    workspace = Workspace(root)..ensureLayout();
    projection = ProjectionStore(workspace);
  });

  tearDown(() {
    projection.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('worker records intent and claim before invoking runner', () async {
    final task = _task();
    TaskRepository(workspace).create(task);
    final runId = ControlService(
      workspace,
      projection,
    ).requestStart(task, 'OPR-worker');
    final result = await TaskExecutionWorker(
      workspace: workspace,
      projection: projection,
      runner: _InspectingRunner(workspace),
      environmentId: 'ENV-worker',
      heartbeatInterval: const Duration(milliseconds: 10),
    ).runNext();

    expect(result?.status, 'completed');
    expect(result?.runId, runId);
    final canonical = CanonicalRepository(workspace);
    expect(canonical.get(EntityKind.run, runId)?.data['status'], 'completed');
    expect(
      TaskRepository(workspace).get(task.id)?.status,
      TaskStatus.completed,
    );
    expect(canonical.list(EntityKind.claim).single.data['status'], 'released');
    final event = canonical
        .list(EntityKind.event)
        .singleWhere(
          (item) => item.data['event_type'] == 'orchestration_completed',
        );
    expect((event.data['process_evidence'] as Map)['exit_code'], 0);
  });

  test('pipeline rejects self reported success without process evidence', () {
    final invalid = OrchestrationResult(
      trace: _trace,
      reviewerScore: 10,
      independentReviewer: true,
      evidence: RunnerEvidence(
        adapterId: 'fake',
        processId: 0,
        exitCode: 1,
        outputSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        startedAt: DateTime.utc(2020),
        finishedAt: DateTime.utc(2020),
        reviewerArtifactSha256:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        artifactVerified: false,
        reviewerSessionId: '',
      ),
    );
    TaskRepository(workspace).create(_task());
    expect(
      () => SkillPipeline(
        projection,
        _ResultRunner(invalid),
      ).execute(_task(), 'RUN-invalid'),
      throwsStateError,
    );
  });

  test('expired worker heartbeat marks run interrupted and task blocked', () {
    final task = _task().copyWith(status: TaskStatus.running);
    TaskRepository(workspace).create(task);
    final canonical = CanonicalRepository(workspace);
    canonical.create(
      CanonicalEntity(
        kind: EntityKind.run,
        id: 'RUN-stale',
        data: {
          'schema_version': 1,
          'id': 'RUN-stale',
          'type': 'run',
          'task_id': task.id,
          'operation_id': 'OPR-stale',
          'status': 'running',
          'created_at': DateTime.utc(2020).toIso8601String(),
        },
      ),
    );
    ClaimService(workspace, projection).acquire(
      taskId: task.id,
      runId: 'RUN-stale',
      environmentId: 'ENV-worker',
      ttl: const Duration(seconds: 1),
      now: DateTime.utc(2020),
    );

    final recovered = TaskExecutionWorker(
      workspace: workspace,
      projection: projection,
      runner: _ResultRunner(_success),
      environmentId: 'ENV-worker',
    ).recoverExpiredRuns(now: DateTime.utc(2020, 1, 1, 0, 1));

    expect(recovered, ['RUN-stale']);
    expect(
      canonical.get(EntityKind.run, 'RUN-stale')?.data['status'],
      'interrupted',
    );
    expect(TaskRepository(workspace).get(task.id)?.status, TaskStatus.blocked);
  });

  test(
    'pending cancel request is ACKed by worker and terminates runner',
    () async {
      final task = _task();
      TaskRepository(workspace).create(task);
      final controls = ControlService(workspace, projection);
      final runId = controls.requestStart(task, 'OPR-cancel-start');
      final runner = _CancellableRunner();
      final future = TaskExecutionWorker(
        workspace: workspace,
        projection: projection,
        runner: runner,
        environmentId: 'ENV-worker',
        heartbeatInterval: const Duration(milliseconds: 5),
      ).runNext();
      await runner.started.future;
      final running = TaskRepository(workspace).get(task.id)!;
      controls.request(
        running,
        ControlCommand.cancel,
        operationId: 'OPR-cancel-run',
        runId: runId,
      );
      final result = await future;
      expect(result?.status, 'cancelled');
      expect(runner.cancelled, isTrue);
      final cancelRequest = CanonicalRepository(workspace)
          .list(EntityKind.controlRequest)
          .singleWhere((item) => item.data['operation_id'] == 'OPR-cancel-run');
      expect(
        controls.dispositionFor(cancelRequest.id)?.data['actor'],
        containsPair('actor_id', 'worker:ENV-worker'),
      );
      expect(
        TaskRepository(workspace).get(task.id)?.status,
        TaskStatus.cancelled,
      );
    },
  );

  test('failed pause is rejected before state mutation', () async {
    final task = _task();
    TaskRepository(workspace).create(task);
    final controls = ControlService(workspace, projection);
    final runId = controls.requestStart(task, 'OPR-pause-fail-start');
    final runner = _FailingPauseRunner();
    final future = TaskExecutionWorker(
      workspace: workspace,
      projection: projection,
      runner: runner,
      environmentId: 'ENV-worker',
      heartbeatInterval: const Duration(milliseconds: 5),
    ).runNext();
    await runner.started.future;
    final running = TaskRepository(workspace).get(task.id)!;
    controls.request(
      running,
      ControlCommand.pause,
      operationId: 'OPR-pause-fail',
      runId: runId,
    );
    CanonicalEntity? disposition;
    for (var attempt = 0; attempt < 100 && disposition == null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final request = CanonicalRepository(workspace)
          .list(EntityKind.controlRequest)
          .where((item) => item.data['operation_id'] == 'OPR-pause-fail')
          .firstOrNull;
      if (request != null) disposition = controls.dispositionFor(request.id);
    }
    expect(disposition?.data['disposition'], 'rejected');
    expect(TaskRepository(workspace).get(task.id)?.status, TaskStatus.running);
    controls.request(
      TaskRepository(workspace).get(task.id)!,
      ControlCommand.cancel,
      operationId: 'OPR-pause-fail-cancel',
      runId: runId,
    );
    expect((await future)?.status, 'cancelled');
  });

  test(
    'claim conflict leaves start pending and reserved run requested',
    () async {
      final task = _task();
      TaskRepository(workspace).create(task);
      final controls = ControlService(workspace, projection);
      final runId = controls.requestStart(task, 'OPR-race');
      ClaimService(workspace, projection).acquire(
        taskId: task.id,
        runId: 'RUN-other',
        environmentId: 'ENV-other',
      );
      final request = CanonicalRepository(
        workspace,
      ).list(EntityKind.controlRequest).single;

      final result = await TaskExecutionWorker(
        workspace: workspace,
        projection: projection,
        runner: _ResultRunner(_success),
        environmentId: 'ENV-worker',
      ).runNext();

      expect(result?.status, 'claim_conflict');
      expect(controls.dispositionFor(request.id), isNull);
      expect(
        CanonicalRepository(
          workspace,
        ).get(EntityKind.run, runId)?.data['status'],
        'requested',
      );
      expect(TaskRepository(workspace).get(task.id)?.status, TaskStatus.ready);
    },
  );

  test(
    'multi-environment execution fails closed without remote lease',
    () async {
      final task = _task().copyWith(
        executionScope: ExecutionScope.multiEnvironment,
      );
      TaskRepository(workspace).create(task);
      final runId = ControlService(
        workspace,
        projection,
      ).requestStart(task, 'OPR-remote-required');
      final runner = _CountingRunner();

      final result = await TaskExecutionWorker(
        workspace: workspace,
        projection: projection,
        runner: runner,
        environmentId: 'ENV-worker',
      ).runNext();

      expect(result?.status, 'remote_claim_required');
      expect(runner.calls, 0);
      expect(
        CanonicalRepository(
          workspace,
        ).get(EntityKind.run, runId)?.data['status'],
        'requested',
      );
      expect(TaskRepository(workspace).get(task.id)?.status, TaskStatus.ready);
    },
  );

  test('every pre-ACK start fault is compensated and recoverable', () async {
    for (final stage in [
      WorkerStartStage.remoteLeaseAcquired,
      WorkerStartStage.localClaimAcquired,
      WorkerStartStage.runMarkedRunning,
      WorkerStartStage.taskMarkedRunning,
      WorkerStartStage.beforeDispositionAccepted,
    ]) {
      final isolated = Directory.systemTemp.createTempSync('worker-fault-');
      final isolatedWorkspace = Workspace(isolated)..ensureLayout();
      final isolatedProjection = ProjectionStore(isolatedWorkspace);
      addTearDown(() {
        isolatedProjection.dispose();
        isolated.deleteSync(recursive: true);
      });
      final task = _task().copyWith(
        executionScope: ExecutionScope.multiEnvironment,
      );
      TaskRepository(isolatedWorkspace).create(task);
      final runId = ControlService(
        isolatedWorkspace,
        isolatedProjection,
      ).requestStart(task, 'OPR-fault-${stage.name}');
      final remote = _MemoryRemoteClaims();

      final result = await TaskExecutionWorker(
        workspace: isolatedWorkspace,
        projection: isolatedProjection,
        runner: _CountingRunner(),
        environmentId: 'ENV-worker',
        remoteClaims: remote,
        faultInjector: (current) {
          if (current == stage) throw StateError('injected ${stage.name}');
        },
      ).runNext();

      final canonical = CanonicalRepository(isolatedWorkspace);
      expect(result?.status, 'claim_conflict');
      expect(canonical.get(EntityKind.run, runId)?.data['status'], 'requested');
      expect(
        TaskRepository(isolatedWorkspace).get(task.id)?.status,
        TaskStatus.ready,
      );
      expect(canonical.list(EntityKind.controlDisposition), isEmpty);
      expect(
        canonical
            .list(EntityKind.claim)
            .every((claim) => claim.data['status'] == 'released'),
        isTrue,
      );
      expect(
        canonical
            .list(EntityKind.event)
            .where((event) => event.data['event_type'] == 'start_compensated'),
        hasLength(1),
      );
      expect(remote.releases, 1);
    }
  });

  test('stale remote owner cannot append result or complete task', () async {
    final task = _task().copyWith(
      executionScope: ExecutionScope.multiEnvironment,
    );
    TaskRepository(workspace).create(task);
    ControlService(
      workspace,
      projection,
    ).requestStart(task, 'OPR-fenced-result');
    final remote = _MemoryRemoteClaims();
    final runner = _GateRunner();
    final future = TaskExecutionWorker(
      workspace: workspace,
      projection: projection,
      runner: runner,
      environmentId: 'ENV-worker',
      remoteClaims: remote,
      heartbeatInterval: const Duration(milliseconds: 5),
    ).runNext();
    await runner.started.future;
    remote.current = false;
    runner.finish.complete();

    final result = await future;
    expect(result?.status, 'fenced_out');
    expect(
      CanonicalRepository(workspace)
          .list(EntityKind.event)
          .where(
            (event) => event.data['event_type'] == 'orchestration_completed',
          ),
      isEmpty,
    );
    expect(
      TaskRepository(workspace).get(task.id)?.status,
      isNot(TaskStatus.completed),
    );
  });

  test('completed event reconciliation is idempotent after crash', () async {
    final task = _task().copyWith(status: TaskStatus.running);
    TaskRepository(workspace).create(task);
    final canonical = CanonicalRepository(workspace);
    canonical.create(
      CanonicalEntity(
        kind: EntityKind.run,
        id: 'RUN-reconcile',
        data: {
          'schema_version': 1,
          'id': 'RUN-reconcile',
          'type': 'run',
          'operation_id': 'OPR-reconcile',
          'task_id': task.id,
          'status': 'running',
          'created_at': DateTime.utc(2020).toIso8601String(),
        },
      ),
    );
    await SkillPipeline(
      projection,
      _ResultRunner(_success),
      manageClaim: false,
    ).execute(task, 'RUN-reconcile');
    final worker = TaskExecutionWorker(
      workspace: workspace,
      projection: projection,
      runner: _CountingRunner(),
      environmentId: 'ENV-worker',
    );

    expect(worker.reconcileCompletedRuns(), ['RUN-reconcile']);
    expect(worker.reconcileCompletedRuns(), isEmpty);
    expect(
      canonical.get(EntityKind.run, 'RUN-reconcile')?.data['status'],
      'completed',
    );
    expect(
      TaskRepository(workspace).get(task.id)?.status,
      TaskStatus.completed,
    );
  });
}

const _trace = [
  SkillInvocation('under-claw-meta-prompt', 'RUN-worker', 0),
  SkillInvocation('under-claw-jarvis-plan-loop', 'RUN-worker', 0),
  SkillInvocation(
    'under-claw-jarvis-plan',
    'RUN-worker',
    1,
    parentSkillId: 'under-claw-jarvis-plan-loop',
  ),
];

final _success = OrchestrationResult(
  trace: _trace,
  reviewerScore: 9.7,
  independentReviewer: true,
  evidence: RunnerEvidence.fixture('worker'),
);

class _InspectingRunner implements RunnerAdapter {
  _InspectingRunner(this.workspace);
  final Workspace workspace;

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    final canonical = CanonicalRepository(workspace);
    expect(
      canonical.get(EntityKind.run, invocation.runId)?.data['status'],
      'running',
    );
    expect(canonical.list(EntityKind.controlDisposition), hasLength(1));
    expect(canonical.list(EntityKind.claim).single.data['status'], 'active');
    return _success;
  }
}

class _ResultRunner implements RunnerAdapter {
  _ResultRunner(this.result);
  final OrchestrationResult result;

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async => result;
}

class _CancellableRunner implements CancellableRunnerAdapter {
  final started = Completer<void>();
  final stopped = Completer<void>();
  bool cancelled = false;

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (!stopped.isCompleted) stopped.complete();
  }

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    started.complete();
    await stopped.future;
    throw StateError('cancelled by worker');
  }
}

class _CountingRunner implements RunnerAdapter {
  int calls = 0;

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    calls++;
    return _success;
  }
}

class _GateRunner implements RunnerAdapter {
  final started = Completer<void>();
  final finish = Completer<void>();

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    started.complete();
    await finish.future;
    return _success;
  }
}

class _FailingPauseRunner
    implements PausableRunnerAdapter, CancellableRunnerAdapter {
  final started = Completer<void>();
  final stopped = Completer<void>();

  @override
  Future<void> pause() async => throw StateError('pause failed');

  @override
  Future<void> resume() async {}

  @override
  Future<void> cancel() async {
    if (!stopped.isCompleted) stopped.complete();
  }

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    started.complete();
    await stopped.future;
    throw StateError('cancelled');
  }
}

class _MemoryRemoteClaims implements RemoteClaimProvider {
  int releases = 0;
  bool current = true;

  @override
  Future<RemoteClaimLease?> tryAcquire({
    required String taskId,
    required String runId,
    required String environmentId,
    required Duration ttl,
    DateTime? now,
  }) async => RemoteClaimLease(
    taskId: taskId,
    runId: runId,
    environmentId: environmentId,
    ref: 'refs/test/$taskId',
    objectId: 'object',
    epoch: 1,
    expiresAt: (now ?? DateTime.now()).toUtc().add(ttl),
  );

  @override
  Future<RemoteClaimLease?> renew(
    RemoteClaimLease lease, {
    required Duration ttl,
    DateTime? now,
  }) async => lease;

  @override
  Future<bool> release(RemoteClaimLease lease) async {
    releases++;
    return true;
  }

  @override
  Future<bool> isCurrent(RemoteClaimLease lease) async => current;
}

WorkTask _task() => const WorkTask(
  id: 'TSK-worker',
  domainId: 'DOM-worker',
  milestoneId: 'MLS-worker',
  title: 'Worker task',
  status: TaskStatus.ready,
  promptDraft: 'draft',
  promptMeta: 'meta',
  promptDraftRevision: 1,
  promptMetaSourceRevision: 1,
  promptMetaSourceSha256:
      '7743ce348d9284d677a185f33295b92266cc435a5b5f775029b300066d26693a',
  approval: PromptApproval.approved,
  autoDeriveTasks: false,
  targetEnvironment: 'ENV-worker',
  executionScope: ExecutionScope.singleMachine,
);
