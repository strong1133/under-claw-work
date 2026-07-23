import 'dart:async';

import 'canonical_repository.dart';
import 'claim_service.dart';
import 'control_service.dart';
import 'git_remote_claim_service.dart';
import 'git_sync_service.dart';
import 'id.dart';
import 'models.dart';
import 'projection.dart';
import 'skill_pipeline.dart';
import 'task_repository.dart';
import 'workspace.dart';

class WorkerRunResult {
  const WorkerRunResult(this.runId, this.status, {this.error});

  final String runId;
  final String status;
  final String? error;
}

enum WorkerStartStage {
  remoteLeaseAcquired,
  localClaimAcquired,
  runMarkedRunning,
  taskMarkedRunning,
  beforeDispositionAccepted,
}

typedef WorkerFaultInjector = void Function(WorkerStartStage stage);

/// Consumes durable start requests. The request and reserved Run always exist
/// before any adapter is invoked.
class TaskExecutionWorker {
  TaskExecutionWorker({
    required this.workspace,
    required this.projection,
    required this.runner,
    required this.environmentId,
    this.heartbeatInterval = const Duration(seconds: 30),
    this.claimTtl = const Duration(minutes: 5),
    this.remoteClaims,
    this.faultInjector,
    this.gitSync,
  });

  final Workspace workspace;
  final ProjectionStore projection;
  final RunnerAdapter runner;
  final String environmentId;
  final Duration heartbeatInterval;
  final Duration claimTtl;
  final RemoteClaimProvider? remoteClaims;
  final WorkerFaultInjector? faultInjector;
  final GitSyncService? gitSync;

  Future<WorkerRunResult?> runNext() async {
    await gitSync?.reconcileForWorker();
    reconcileCompletedRuns();
    final repository = CanonicalRepository(workspace);
    final requests =
        repository
            .list(EntityKind.controlRequest)
            .where(
              (item) =>
                  item.data['command'] == ControlCommand.start.name &&
                  item.data['target_environment_id'] == environmentId &&
                  ControlService(
                        workspace,
                        projection,
                      ).dispositionFor(item.id) ==
                      null,
            )
            .toList()
          ..sort(
            (left, right) => (left.data['requested_at'] as String).compareTo(
              right.data['requested_at'] as String,
            ),
          );
    if (requests.isEmpty) return null;
    return executeRequest(requests.first.id);
  }

  Future<WorkerRunResult> executeRequest(String requestId) async {
    final repository = CanonicalRepository(workspace);
    final request = repository.get(EntityKind.controlRequest, requestId);
    if (request == null) {
      throw StateError('Control request does not exist: $requestId');
    }
    if (request.data['command'] != ControlCommand.start.name) {
      throw StateError('Worker only executes start requests.');
    }
    if (request.data['target_environment_id'] != environmentId) {
      throw StateError('Start request targets another environment.');
    }
    final runId = request.data['reserved_run_id'] as String;
    final taskId = request.data['task_id'] as String;
    final taskRepository = TaskRepository(workspace);
    final task = taskRepository.get(taskId);
    if (task == null) throw StateError('Task does not exist: $taskId');

    final controls = ControlService(workspace, projection);
    final existingDisposition = controls.dispositionFor(requestId);
    if (existingDisposition != null &&
        existingDisposition.data['disposition'] != 'accepted') {
      return WorkerRunResult(runId, 'not_started');
    }
    if (request.data['expected_task_revision'] != task.promptDraftRevision) {
      controls.addDisposition(
        requestId,
        'rejected',
        actorId: 'worker:$environmentId',
        reason: 'Task revision changed before execution.',
      );
      return WorkerRunResult(runId, 'stale_request');
    }

    final claims = ClaimService(workspace, projection);
    CanonicalEntity? claim;
    RemoteClaimLease? remoteLease;
    var startCommitted = existingDisposition != null;
    final priorRun = repository.get(EntityKind.run, runId)!;
    final priorTask = task;
    if (existingDisposition?.data['disposition'] == 'accepted' &&
        priorRun.data['status'] == 'running' &&
        _hasEvent(repository, runId, 'runner_invocation_started')) {
      _updateRun(repository, runId, 'interrupted', {
        'finished_at': DateTime.now().toUtc().toIso8601String(),
        'failure_type': 'worker_restart_after_runner_invocation',
      });
      if (task.status == TaskStatus.running) {
        taskRepository.update(task.copyWith(status: TaskStatus.blocked));
      }
      projection.rebuild();
      await gitSync?.publishWorkerChanges(
        operationId: request.data['operation_id'] as String,
      );
      return WorkerRunResult(runId, 'recovered_interrupted');
    }
    try {
      if (task.executionScope == ExecutionScope.multiEnvironment) {
        final provider = remoteClaims;
        if (provider == null) {
          throw StateError(
            'REMOTE_CLAIM_REQUIRED: multi-environment Task fails closed.',
          );
        }
        remoteLease = await provider.tryAcquire(
          taskId: taskId,
          runId: runId,
          environmentId: environmentId,
          ttl: claimTtl,
        );
        if (remoteLease == null) {
          return WorkerRunResult(runId, 'claim_conflict');
        }
        faultInjector?.call(WorkerStartStage.remoteLeaseAcquired);
      }
      claim = claims.acquire(
        taskId: taskId,
        runId: runId,
        environmentId: environmentId,
        ttl: claimTtl,
      );
      faultInjector?.call(WorkerStartStage.localClaimAcquired);
      _updateRun(repository, runId, 'running', {
        'worker_environment_id': environmentId,
        'worker_started_at': DateTime.now().toUtc().toIso8601String(),
      });
      faultInjector?.call(WorkerStartStage.runMarkedRunning);
      taskRepository.update(task.copyWith(status: TaskStatus.running));
      faultInjector?.call(WorkerStartStage.taskMarkedRunning);
      faultInjector?.call(WorkerStartStage.beforeDispositionAccepted);
      if (existingDisposition == null) {
        controls.addDisposition(
          requestId,
          'accepted',
          actorId: 'worker:$environmentId',
          rebuildProjection: false,
        );
      }
      startCommitted = true;
      projection.rebuild();
    } on Object catch (error) {
      if (!startCommitted) {
        await _compensateStart(
          repository: repository,
          tasks: taskRepository,
          claims: claims,
          claim: claim,
          remoteLease: remoteLease,
          priorRun: priorRun,
          priorTask: priorTask,
          requestId: requestId,
          error: error,
        );
        return WorkerRunResult(
          runId,
          error is StateError &&
                  error.toString().contains('REMOTE_CLAIM_REQUIRED')
              ? 'remote_claim_required'
              : 'claim_conflict',
          error: error.toString(),
        );
      }
      rethrow;
    }

    var cancelled = false;
    var paused = false;
    var pipelineFinished = false;
    Object? controlFailure;
    Future<void> requireCurrentFence() async {
      final lease = remoteLease;
      if (lease != null && !await remoteClaims!.isCurrent(lease)) {
        throw StateError('REMOTE_FENCE_LOST');
      }
    }

    _createRunEventOnce(repository, runId, 'runner_invocation_started');
    projection.rebuild();
    await requireCurrentFence();
    await gitSync?.publishWorkerChanges(
      operationId: request.data['operation_id'] as String,
    );
    // Close the short-task window: prove ownership immediately before the
    // adapter starts, not only at the first periodic heartbeat.
    await requireCurrentFence();
    final pipelineFuture = SkillPipeline(
      projection,
      runner,
      environmentId: environmentId,
      manageClaim: false,
      beforeCanonicalWrite: requireCurrentFence,
    ).execute(task, runId).whenComplete(() => pipelineFinished = true);
    final controlFuture =
        () async {
          while (!pipelineFinished) {
            await Future<void>.delayed(heartbeatInterval);
            if (pipelineFinished) break;
            claims.heartbeat(claim!.id, ttl: claimTtl);
            // The remote OID is the ownership token. We intentionally keep it
            // stable while canonical writes are in flight; wall-clock renewal
            // would rotate the token concurrently and fence the owner itself.
            await requireCurrentFence();
            final state = await _consumePendingControls(runId, paused: paused);
            cancelled = cancelled || state.cancelled;
            paused = state.paused;
            if (state.processed) {
              await requireCurrentFence();
              await gitSync?.publishWorkerChanges(
                operationId: request.data['operation_id'] as String,
              );
            }
          }
        }().catchError((Object error) {
          controlFailure = error;
        });
    try {
      await pipelineFuture;
      await controlFuture;
      if (controlFailure != null) throw controlFailure!;
      await requireCurrentFence();
      if (cancelled) {
        _updateRun(repository, runId, 'cancelled', {
          'finished_at': DateTime.now().toUtc().toIso8601String(),
        });
        taskRepository.update(task.copyWith(status: TaskStatus.cancelled));
        projection.rebuild();
        await gitSync?.publishWorkerChanges(
          operationId: request.data['operation_id'] as String,
        );
        return WorkerRunResult(runId, 'cancelled');
      }
      await requireCurrentFence();
      _updateRun(repository, runId, 'completed', {
        'finished_at': DateTime.now().toUtc().toIso8601String(),
      });
      taskRepository.update(task.copyWith(status: TaskStatus.completed));
      projection.rebuild();
      await gitSync?.publishWorkerChanges(
        operationId: request.data['operation_id'] as String,
      );
      return WorkerRunResult(runId, 'completed');
    } on Object catch (error) {
      await controlFuture;
      if (error is StateError &&
          error.toString().contains('REMOTE_FENCE_LOST')) {
        // A fenced-out worker must not append failure/cancel/result state.
        return WorkerRunResult(runId, 'fenced_out', error: error.toString());
      }
      if (cancelled) {
        _updateRun(repository, runId, 'cancelled', {
          'finished_at': DateTime.now().toUtc().toIso8601String(),
        });
        final current = taskRepository.get(taskId);
        if (current != null && current.status != TaskStatus.cancelled) {
          taskRepository.update(current.copyWith(status: TaskStatus.cancelled));
        }
        projection.rebuild();
        return WorkerRunResult(runId, 'cancelled');
      }
      _updateRun(repository, runId, 'failed', {
        'finished_at': DateTime.now().toUtc().toIso8601String(),
        'failure_type': error.runtimeType.toString(),
      });
      final current = taskRepository.get(taskId);
      if (current != null && current.status == TaskStatus.running) {
        taskRepository.update(current.copyWith(status: TaskStatus.blocked));
      }
      projection.rebuild();
      return WorkerRunResult(runId, 'failed', error: error.toString());
    } finally {
      pipelineFinished = true;
      final current = repository.get(EntityKind.claim, claim.id);
      if (current?.data['status'] == 'active') claims.release(claim.id);
      if (remoteLease != null) await remoteClaims?.release(remoteLease);
    }
  }

  List<String> recoverExpiredRuns({DateTime? now}) {
    final instant = (now ?? DateTime.now()).toUtc();
    final repository = CanonicalRepository(workspace);
    final recovered = <String>[];
    for (final claim in repository.list(EntityKind.claim)) {
      if (claim.data['status'] != 'active' ||
          DateTime.parse(claim.data['expires_at'] as String).isAfter(instant)) {
        continue;
      }
      final runId = claim.data['run_id'] as String;
      final run = repository.get(EntityKind.run, runId);
      if (run != null && run.data['status'] == 'running') {
        _updateRun(repository, runId, 'interrupted', {
          'finished_at': instant.toIso8601String(),
          'failure_type': 'stale_worker_heartbeat',
        });
        final task = TaskRepository(
          workspace,
        ).get(claim.data['task_id'] as String);
        if (task != null && task.status == TaskStatus.running) {
          TaskRepository(
            workspace,
          ).update(task.copyWith(status: TaskStatus.blocked));
        }
        recovered.add(runId);
      }
      repository.update(
        CanonicalEntity(
          kind: EntityKind.claim,
          id: claim.id,
          data: {
            ...claim.data,
            'status': 'released',
            'released_at': instant.toIso8601String(),
          },
        ),
      );
    }
    if (recovered.isNotEmpty) projection.rebuild();
    return recovered;
  }

  /// Completes the small crash window between the immutable orchestration
  /// result event and mutable Run/Task terminal projections. Safe to repeat.
  List<String> reconcileCompletedRuns() {
    final repository = CanonicalRepository(workspace);
    final tasks = TaskRepository(workspace);
    final recovered = <String>[];
    for (final event in repository.list(EntityKind.event)) {
      if (event.data['event_type'] != 'orchestration_completed') continue;
      final runId = event.data['run_id'] as String?;
      if (runId == null) continue;
      final run = repository.get(EntityKind.run, runId);
      if (run == null ||
          const {
            'completed',
            'cancelled',
            'failed',
          }.contains(run.data['status'])) {
        continue;
      }
      _updateRun(repository, runId, 'completed', {
        'finished_at':
            event.data['occurred_at'] ??
            DateTime.now().toUtc().toIso8601String(),
        'reconciled_from_event_id': event.id,
      });
      final taskId = run.data['task_id'] as String;
      final task = tasks.get(taskId);
      if (task != null && task.status != TaskStatus.completed) {
        tasks.update(task.copyWith(status: TaskStatus.completed));
      }
      recovered.add(runId);
    }
    if (recovered.isNotEmpty) projection.rebuild();
    return recovered;
  }

  void _updateRun(
    CanonicalRepository repository,
    String runId,
    String status,
    Map<String, Object?> fields,
  ) {
    final run = repository.get(EntityKind.run, runId);
    if (run == null) throw StateError('Reserved Run does not exist: $runId');
    repository.update(
      CanonicalEntity(
        kind: EntityKind.run,
        id: run.id,
        data: {...run.data, 'status': status, ...fields},
      ),
    );
  }

  bool _hasEvent(
    CanonicalRepository repository,
    String runId,
    String eventType,
  ) => repository
      .list(EntityKind.event)
      .any(
        (event) =>
            event.data['run_id'] == runId &&
            event.data['event_type'] == eventType,
      );

  void _createRunEventOnce(
    CanonicalRepository repository,
    String runId,
    String eventType,
  ) {
    if (_hasEvent(repository, runId, eventType)) return;
    final eventId =
        'EVT-${eventType.replaceAll('_', '-')}-${runId.substring(4)}';
    repository.create(
      CanonicalEntity(
        kind: EntityKind.event,
        id: eventId,
        data: {
          'schema_version': 1,
          'id': eventId,
          'type': 'event',
          'event_type': eventType,
          'run_id': runId,
          'occurred_at': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
  }

  Future<({bool cancelled, bool paused, bool processed})>
  _consumePendingControls(String runId, {required bool paused}) async {
    final repository = CanonicalRepository(workspace);
    final controls = ControlService(workspace, projection);
    var cancelled = false;
    var processed = false;
    final requests =
        repository
            .list(EntityKind.controlRequest)
            .where(
              (item) =>
                  item.data['run_id'] == runId &&
                  controls.dispositionFor(item.id) == null,
            )
            .toList()
          ..sort(
            (left, right) => ((left.data['control_sequence'] as int?) ?? 0)
                .compareTo((right.data['control_sequence'] as int?) ?? 0),
          );
    for (final request in requests) {
      processed = true;
      final task = TaskRepository(
        workspace,
      ).get(request.data['task_id'] as String);
      if (task == null ||
          request.data['expected_task_revision'] != task.promptDraftRevision) {
        controls.addDisposition(
          request.id,
          'rejected',
          actorId: 'worker:$environmentId',
          reason: 'Task revision changed before control processing.',
        );
        continue;
      }
      final command = ControlCommand.values.byName(
        request.data['command'] as String,
      );
      final currentRunner = runner;
      if (command == ControlCommand.cancel) {
        if (currentRunner is CancellableRunnerAdapter) {
          try {
            await currentRunner.cancel();
          } on Object catch (error) {
            controls.addDisposition(
              request.id,
              'rejected',
              actorId: 'worker:$environmentId',
              reason: 'Runner cancel failed: ${error.runtimeType}.',
            );
            continue;
          }
        }
        controls.addDisposition(
          request.id,
          'accepted',
          actorId: 'worker:$environmentId',
        );
        cancelled = true;
        break;
      }
      if (command == ControlCommand.pause) {
        if (currentRunner is! PausableRunnerAdapter) {
          controls.addDisposition(
            request.id,
            'rejected',
            actorId: 'worker:$environmentId',
            reason: 'Configured runner does not support pause.',
          );
          continue;
        }
        try {
          await currentRunner.pause();
        } on Object catch (error) {
          controls.addDisposition(
            request.id,
            'rejected',
            actorId: 'worker:$environmentId',
            reason: 'Runner pause failed: ${error.runtimeType}.',
          );
          continue;
        }
        controls.addDisposition(
          request.id,
          'accepted',
          actorId: 'worker:$environmentId',
        );
        paused = true;
        _setTaskAndRunStatus(
          request.data['task_id'] as String,
          runId,
          TaskStatus.paused,
        );
        continue;
      }
      if (command == ControlCommand.resume) {
        if (!paused || currentRunner is! PausableRunnerAdapter) {
          controls.addDisposition(
            request.id,
            'rejected',
            actorId: 'worker:$environmentId',
            reason: 'Run is not paused by a pause-capable runner.',
          );
          continue;
        }
        try {
          await currentRunner.resume();
        } on Object catch (error) {
          controls.addDisposition(
            request.id,
            'rejected',
            actorId: 'worker:$environmentId',
            reason: 'Runner resume failed: ${error.runtimeType}.',
          );
          continue;
        }
        controls.addDisposition(
          request.id,
          'accepted',
          actorId: 'worker:$environmentId',
        );
        paused = false;
        _setTaskAndRunStatus(
          request.data['task_id'] as String,
          runId,
          TaskStatus.running,
        );
        continue;
      }
      // complete is a result acknowledgment, never a way to bypass the
      // orchestration/reviewer gate.
      controls.addDisposition(
        request.id,
        'rejected',
        actorId: 'worker:$environmentId',
        reason: 'Completion is produced only by a verified pipeline result.',
      );
    }
    return (cancelled: cancelled, paused: paused, processed: processed);
  }

  Future<void> _compensateStart({
    required CanonicalRepository repository,
    required TaskRepository tasks,
    required ClaimService claims,
    required CanonicalEntity? claim,
    required RemoteClaimLease? remoteLease,
    required CanonicalEntity priorRun,
    required WorkTask priorTask,
    required String requestId,
    required Object error,
  }) async {
    repository.update(priorRun);
    tasks.update(priorTask);
    if (claim != null) {
      final current = repository.get(EntityKind.claim, claim.id);
      if (current?.data['status'] == 'active') claims.release(claim.id);
    }
    var remoteReleasePending = false;
    if (remoteLease != null) {
      try {
        remoteReleasePending = await remoteClaims?.release(remoteLease) != true;
      } on Object {
        remoteReleasePending = true;
      }
    }
    final eventId = newId('EVT');
    repository.create(
      CanonicalEntity(
        kind: EntityKind.event,
        id: eventId,
        data: {
          'schema_version': 1,
          'id': eventId,
          'type': 'event',
          'event_type': 'start_compensated',
          'request_id': requestId,
          'failure_type': error.runtimeType.toString(),
          'remote_release_pending': remoteReleasePending,
          'occurred_at': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
    projection.rebuild();
  }

  void _setTaskAndRunStatus(String taskId, String runId, TaskStatus status) {
    final tasks = TaskRepository(workspace);
    final task = tasks.get(taskId);
    if (task != null && task.status != status) {
      tasks.update(task.copyWith(status: status));
    }
    final repository = CanonicalRepository(workspace);
    final run = repository.get(EntityKind.run, runId);
    if (run != null && run.data['status'] != status.name) {
      repository.update(
        CanonicalEntity(
          kind: EntityKind.run,
          id: run.id,
          data: {...run.data, 'status': status.name},
        ),
      );
    }
    projection.rebuild();
  }
}
