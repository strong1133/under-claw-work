import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'canonical_secret_verifier.dart';
import 'canonical_repository.dart';
import 'canonical_sync_service.dart';
import 'git_remote_claim_service.dart';
import 'id.dart';
import 'meta_prompt_service.dart';
import 'models.dart';
import 'notification_service.dart';
import 'task_codec.dart';
import 'task_repository.dart';
import 'workspace.dart';
import 'workspace_mutation_lock.dart';

abstract interface class CanonicalMetaPublisher {
  Future<void> publish(
    String message,
    RemoteClaimLease lease, {
    WorkTask? expectedTask,
  });
}

class GitCanonicalMetaPublisher implements CanonicalMetaPublisher {
  GitCanonicalMetaPublisher(this.workspace);

  final Workspace workspace;

  @override
  Future<void> publish(
    String message,
    RemoteClaimLease lease, {
    WorkTask? expectedTask,
  }) async {
    final committedFileSha256 = <String, String>{};
    if (expectedTask != null) {
      final file = TaskRepository(workspace).canonicalFile(expectedTask.id);
      final expectedBytes = utf8.encode(TaskCodec.encode(expectedTask));
      if (!_bytesEqual(file.readAsBytesSync(), expectedBytes)) {
        throw StateError('CANONICAL_EXPECTED_TASK_CHANGED: ${expectedTask.id}');
      }
      final relativePath = p.posix.joinAll(
        p.relative(file.path, from: workspace.root.path).split(p.separator),
      );
      committedFileSha256[relativePath] = sha256
          .convert(expectedBytes)
          .toString();
    }
    await CanonicalSyncService(workspace).syncCanonical(
      message: message,
      verifier: const CanonicalSecretVerifier(),
      remoteRefLeases: {lease.ref: lease.objectId},
      committedFileSha256: committedFileSha256,
    );
  }

  static bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

enum AutoMetaRunStatus { generated, generatedWithNotificationFailure }

class AutoMetaRunResult {
  const AutoMetaRunResult({
    required this.taskId,
    required this.status,
    required this.outputSha256,
  });

  final String taskId;
  final AutoMetaRunStatus status;
  final String outputSha256;
}

class AutoMetaWorker {
  AutoMetaWorker({
    required this.workspace,
    required this.environmentId,
    required this.adapterId,
    required this.claims,
    MetaPromptService? generator,
    CanonicalMetaPublisher? publisher,
    MetaReadyNotifier? notifier,
    this.claimTtl = const Duration(minutes: 10),
  }) : generator = generator ?? MetaPromptService(workspace),
       publisher = publisher ?? GitCanonicalMetaPublisher(workspace),
       notifier = notifier ?? const NoopMetaReadyNotifier();

  final Workspace workspace;
  final String environmentId;
  final String adapterId;
  final RemoteClaimProvider claims;
  final MetaPromptService generator;
  final CanonicalMetaPublisher publisher;
  final MetaReadyNotifier notifier;
  final Duration claimTtl;

  static bool isEligible(WorkTask task) {
    if (task.promptDraft.trim().isEmpty) return false;
    if (task.processingMode != TaskProcessingMode.automatic ||
        task.status != TaskStatus.metaRequested) {
      return false;
    }
    final sourceHashChanged =
        task.promptMetaSourceSha256 !=
        TaskRepository.draftSha256(task.promptDraft);
    return task.promptMeta.trim().isEmpty ||
        sourceHashChanged ||
        task.approval == PromptApproval.missing ||
        task.approval == PromptApproval.stale;
  }

  Future<AutoMetaRunResult?> runNext() =>
      WorkspaceMutationLock.runExclusive(workspace, _runNextMutationLocked);

  Future<AutoMetaRunResult?> _runNextMutationLocked() async {
    final repository = TaskRepository(workspace);
    final candidates = repository.list().where(isEligible).toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    for (final candidate in candidates) {
      final runId = newId('RUN');
      final lease = await claims.tryAcquire(
        taskId: candidate.id,
        runId: runId,
        environmentId: environmentId,
        ttl: claimTtl,
      );
      if (lease == null) continue;
      var activeLease = lease;
      try {
        final source = repository.get(candidate.id);
        if (source == null || !isEligible(source)) continue;
        if (!await claims.isCurrent(activeLease)) continue;
        final startLease = await claims.renew(activeLease, ttl: claimTtl);
        if (startLease == null) continue;
        activeLease = startLease;
        final descriptor = generator.runtimes.require(
          adapterId,
          capability: 'generate_meta',
        );
        final startAudit = _recordStartAudit(
          source: source,
          runId: runId,
          executableSha256: descriptor.executableSha256,
        );
        try {
          await publisher.publish(
            'worklog: start Meta Prompt generation for ${source.id} rev '
            '${source.promptDraftRevision}',
            activeLease,
          );
        } catch (_) {
          _removeAudit([startAudit]);
          rethrow;
        }
        if (!await claims.isCurrent(activeLease)) continue;
        final fencedSource = repository.get(source.id);
        if (fencedSource == null ||
            !isEligible(fencedSource) ||
            fencedSource.promptDraftRevision != source.promptDraftRevision ||
            fencedSource.promptDraft != source.promptDraft) {
          continue;
        }
        late final MetaPromptGenerationResult generated;
        try {
          generated = await generator.generate(
            taskId: fencedSource.id,
            adapterId: adapterId,
            recordAudit: false,
          );
        } on Object catch (error) {
          final failureAudit = _recordFailureAudit(
            source: fencedSource,
            runId: runId,
            executableSha256: descriptor.executableSha256,
            errorType: error.runtimeType.toString(),
          );
          RemoteClaimLease? failureLease;
          try {
            failureLease = await claims.renew(activeLease, ttl: claimTtl);
          } catch (_) {
            _removeAudit(failureAudit);
            rethrow;
          }
          if (failureLease != null) {
            activeLease = failureLease;
            try {
              await publisher.publish(
                'worklog: record failed Meta Prompt generation for '
                '${fencedSource.id} rev ${fencedSource.promptDraftRevision}',
                activeLease,
              );
            } catch (_) {
              _removeAudit(failureAudit);
            }
          } else {
            _removeAudit(failureAudit);
          }
          rethrow;
        }
        final expectedSourceSha256 = TaskRepository.draftSha256(
          fencedSource.promptDraft,
        );
        final currentAfterGeneration = repository.get(fencedSource.id);
        if (currentAfterGeneration == null ||
            !_sameTask(currentAfterGeneration, generated.task) ||
            generated.task.promptDraftRevision !=
                fencedSource.promptDraftRevision ||
            generated.task.promptDraft != fencedSource.promptDraft ||
            generated.task.promptMetaSourceRevision !=
                fencedSource.promptDraftRevision ||
            generated.task.promptMetaSourceSha256 != expectedSourceSha256) {
          _discardGeneratedMeta(repository, generated.task);
          continue;
        }
        late final bool ownsGeneratedLease;
        try {
          ownsGeneratedLease = await claims.isCurrent(activeLease);
        } catch (_) {
          _discardGeneratedMeta(repository, generated.task);
          rethrow;
        }
        if (!ownsGeneratedLease) {
          _discardGeneratedMeta(repository, generated.task);
          continue;
        }
        final audit = _recordSuccessAudit(
          source: fencedSource,
          generated: generated,
          runId: runId,
        );
        late final bool ownsAuditedLease;
        try {
          ownsAuditedLease = await claims.isCurrent(activeLease);
        } catch (_) {
          _removeAudit(audit);
          _discardGeneratedMeta(repository, generated.task);
          rethrow;
        }
        if (!ownsAuditedLease) {
          _removeAudit(audit);
          _discardGeneratedMeta(repository, generated.task);
          continue;
        }
        RemoteClaimLease? publishLease;
        try {
          publishLease = await claims.renew(activeLease, ttl: claimTtl);
        } catch (_) {
          _removeAudit(audit);
          _discardGeneratedMeta(repository, generated.task);
          rethrow;
        }
        if (publishLease == null) {
          _removeAudit(audit);
          _discardGeneratedMeta(repository, generated.task);
          continue;
        }
        activeLease = publishLease;
        try {
          await publisher.publish(
            'worklog: generate Meta Prompt for ${fencedSource.id} rev '
            '${fencedSource.promptDraftRevision}',
            activeLease,
            expectedTask: generated.task,
          );
        } catch (_) {
          _removeAudit(audit);
          _discardGeneratedMeta(repository, generated.task);
          rethrow;
        }
        var status = AutoMetaRunStatus.generated;
        final currentAfterPublish = repository.get(generated.task.id);
        if (currentAfterPublish != null &&
            _sameTask(currentAfterPublish, generated.task)) {
          try {
            final report = await notifier.notifyMetaReady(
              MetaReadyNotification(
                taskId: generated.task.id,
                title: generated.task.title,
                sourceRevision: generated.task.promptMetaSourceRevision,
                sourceSha256: generated.task.promptMetaSourceSha256,
                environmentId: environmentId,
                adapterId: generated.adapterId,
              ),
            );
            if (report.failed > 0) {
              status = AutoMetaRunStatus.generatedWithNotificationFailure;
            }
          } catch (_) {
            status = AutoMetaRunStatus.generatedWithNotificationFailure;
          }
        }
        return AutoMetaRunResult(
          taskId: generated.task.id,
          status: status,
          outputSha256: generated.outputSha256,
        );
      } finally {
        await claims.release(activeLease);
      }
    }
    return null;
  }

  void _discardGeneratedMeta(TaskRepository repository, WorkTask generated) {
    repository.compareAndSwap(
      generated,
      generated.copyWith(
        promptMeta: '',
        promptMetaSourceRevision: 0,
        promptMetaSourceSha256: '',
        approval: PromptApproval.stale,
        status: TaskStatus.metaRequested,
      ),
    );
  }

  bool _sameTask(WorkTask left, WorkTask right) =>
      TaskCodec.encode(left) == TaskCodec.encode(right);

  (EntityKind, String) _recordStartAudit({
    required WorkTask source,
    required String runId,
    required String executableSha256,
  }) {
    final eventId = newId('EVT');
    CanonicalRepository(workspace).create(
      CanonicalEntity(
        kind: EntityKind.event,
        id: eventId,
        data: {
          'schema_version': 1,
          'id': eventId,
          'type': 'event',
          'event_type': 'meta_prompt_generation_started',
          'occurred_at': DateTime.now().toUtc().toIso8601String(),
          'task_id': source.id,
          'attempt_run_id': runId,
          'environment_id': environmentId,
          'adapter_id': adapterId,
          'adapter_executable_sha256': executableSha256,
          'source_revision': source.promptDraftRevision,
          'source_sha256': TaskRepository.draftSha256(source.promptDraft),
          'scope': {
            'task_ids': [source.id],
          },
        },
      ),
    );
    return (EntityKind.event, eventId);
  }

  List<(EntityKind, String)> _recordFailureAudit({
    required WorkTask source,
    required String runId,
    required String executableSha256,
    required String errorType,
  }) {
    final canonical = CanonicalRepository(workspace);
    final now = DateTime.now().toUtc().toIso8601String();
    final sourceSha256 = TaskRepository.draftSha256(source.promptDraft);
    final operationId = newId('OPR');
    final invocationId = newId('SKI');
    final eventId = newId('EVT');
    canonical.create(
      CanonicalEntity(
        kind: EntityKind.run,
        id: runId,
        data: {
          'schema_version': 1,
          'id': runId,
          'type': 'run',
          'task_id': source.id,
          'operation_id': operationId,
          'status': 'failed',
          'purpose': 'automatic_meta_prompt_generation',
          'environment_id': environmentId,
          'adapter_id': adapterId,
          'adapter_executable_sha256': executableSha256,
          'source_revision': source.promptDraftRevision,
          'source_sha256': sourceSha256,
          'error_type': errorType,
          'started_at': now,
          'finished_at': now,
        },
      ),
    );
    canonical.create(
      CanonicalEntity(
        kind: EntityKind.invocation,
        id: invocationId,
        data: {
          'schema_version': 1,
          'id': invocationId,
          'type': 'skill_invocation',
          'run_id': runId,
          'skill_id': 'under-claw-meta-prompt',
          'round': 0,
          'sequence': 1,
          'bundle_version': 'installed-runtime-v1',
          'status': 'failed',
          'adapter_id': adapterId,
          'adapter_executable_sha256': executableSha256,
          'source_revision': source.promptDraftRevision,
          'source_sha256': sourceSha256,
          'error_type': errorType,
          'started_at': now,
          'finished_at': now,
        },
      ),
    );
    canonical.create(
      CanonicalEntity(
        kind: EntityKind.event,
        id: eventId,
        data: {
          'schema_version': 1,
          'id': eventId,
          'type': 'event',
          'event_type': 'meta_prompt_generation_failed',
          'occurred_at': now,
          'task_id': source.id,
          'run_id': runId,
          'environment_id': environmentId,
          'adapter_id': adapterId,
          'adapter_executable_sha256': executableSha256,
          'source_revision': source.promptDraftRevision,
          'source_sha256': sourceSha256,
          'error_type': errorType,
          'scope': {
            'task_ids': [source.id],
            'run_ids': [runId],
          },
        },
      ),
    );
    return [
      (EntityKind.run, runId),
      (EntityKind.invocation, invocationId),
      (EntityKind.event, eventId),
    ];
  }

  List<(EntityKind, String)> _recordSuccessAudit({
    required WorkTask source,
    required MetaPromptGenerationResult generated,
    required String runId,
  }) {
    final canonical = CanonicalRepository(workspace);
    final now = DateTime.now().toUtc().toIso8601String();
    final sourceSha256 = TaskRepository.draftSha256(source.promptDraft);
    final operationId = newId('OPR');
    final invocationId = newId('SKI');
    final eventId = newId('EVT');
    canonical.create(
      CanonicalEntity(
        kind: EntityKind.run,
        id: runId,
        data: {
          'schema_version': 1,
          'id': runId,
          'type': 'run',
          'task_id': source.id,
          'operation_id': operationId,
          'status': 'completed',
          'purpose': 'automatic_meta_prompt_generation',
          'environment_id': environmentId,
          'adapter_id': generated.adapterId,
          'adapter_executable_sha256': generated.executableSha256,
          'source_revision': source.promptDraftRevision,
          'source_sha256': sourceSha256,
          'output_sha256': generated.outputSha256,
          'result_sha256': TaskRepository.draftSha256(
            generated.task.promptMeta,
          ),
          'result_ref': 'task:${source.id}#meta@${source.promptDraftRevision}',
          'started_at': now,
          'finished_at': now,
        },
      ),
    );
    canonical.create(
      CanonicalEntity(
        kind: EntityKind.invocation,
        id: invocationId,
        data: {
          'schema_version': 1,
          'id': invocationId,
          'type': 'skill_invocation',
          'run_id': runId,
          'skill_id': 'under-claw-meta-prompt',
          'round': 0,
          'sequence': 1,
          'bundle_version': 'installed-runtime-v1',
          'status': 'completed',
          'adapter_id': generated.adapterId,
          'adapter_executable_sha256': generated.executableSha256,
          'source_revision': source.promptDraftRevision,
          'source_sha256': sourceSha256,
          'output_sha256': generated.outputSha256,
          'result_sha256': TaskRepository.draftSha256(
            generated.task.promptMeta,
          ),
          'result_ref': 'task:${source.id}#meta@${source.promptDraftRevision}',
          'started_at': now,
          'finished_at': now,
        },
      ),
    );
    canonical.create(
      CanonicalEntity(
        kind: EntityKind.event,
        id: eventId,
        data: {
          'schema_version': 1,
          'id': eventId,
          'type': 'event',
          'event_type': 'meta_prompt_generated',
          'occurred_at': now,
          'task_id': source.id,
          'run_id': runId,
          'source_revision': source.promptDraftRevision,
          'source_sha256': sourceSha256,
          'output_sha256': generated.outputSha256,
          'scope': {
            'task_ids': [source.id],
            'run_ids': [runId],
          },
        },
      ),
    );
    return [
      (EntityKind.run, runId),
      (EntityKind.invocation, invocationId),
      (EntityKind.event, eventId),
    ];
  }

  void _removeAudit(List<(EntityKind, String)> audit) {
    final canonical = CanonicalRepository(workspace);
    for (final entry in audit.reversed) {
      final file = canonical.fileFor(entry.$1, entry.$2);
      if (file.existsSync()) file.deleteSync();
    }
  }
}
