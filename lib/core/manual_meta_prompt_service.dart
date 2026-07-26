import 'canonical_repository.dart';
import 'id.dart';
import 'models.dart';
import 'task_repository.dart';
import 'workspace.dart';
import 'workspace_mutation_lock.dart';

class ManualMetaPromptRecord {
  const ManualMetaPromptRecord({
    required this.task,
    required this.runId,
    required this.invocationId,
    required this.eventId,
  });

  final WorkTask task;
  final String runId;
  final String invocationId;
  final String eventId;
}

/// Records a host-executed `under-claw-meta-prompt` result without pretending
/// that host-reported evidence is independently attested.
class ManualMetaPromptService {
  ManualMetaPromptService(this.workspace);

  static const skillId = 'under-claw-meta-prompt';
  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static final _portableResultRef = RegExp(
    r'^task:(TSK-[A-Za-z0-9_-]+)#meta@([0-9]+)$',
  );

  final Workspace workspace;

  ManualMetaPromptRecord recordCompleted({
    required String taskId,
    required String metaPrompt,
    required Map<String, Object?> evidence,
    String evidenceKind = 'host_reported',
  }) {
    return WorkspaceMutationLock.runExclusiveSync(
      workspace,
      () => _recordCompleted(
        taskId: taskId,
        metaPrompt: metaPrompt,
        evidence: evidence,
        evidenceKind: evidenceKind,
      ),
    );
  }

  ManualMetaPromptRecord _recordCompleted({
    required String taskId,
    required String metaPrompt,
    required Map<String, Object?> evidence,
    required String evidenceKind,
  }) {
    if (!const {'host_reported', 'runtime_observed'}.contains(evidenceKind)) {
      throw ArgumentError.value(evidenceKind, 'evidenceKind');
    }
    final tasks = TaskRepository(workspace);
    final source = tasks.get(taskId);
    if (source == null) throw StateError('Task not found: $taskId.');
    if (metaPrompt.trim().isEmpty) {
      throw const FormatException('Meta Prompt must not be empty.');
    }
    _validateEvidence(source, metaPrompt, evidence);

    final canonical = CanonicalRepository(workspace);
    final hostInvocationId = evidence['host_invocation_id'] as String;
    if (canonical
        .list(EntityKind.invocation)
        .any((item) => item.data['host_invocation_id'] == hostInvocationId)) {
      throw StateError('Host invocation was already recorded.');
    }

    final runId = newId('RUN');
    final operationId = newId('OPR');
    final invocationId = newId('SKI');
    final eventId = newId('EVT');
    final sourceSha256 = TaskRepository.draftSha256(source.promptDraft);
    final resultSha256 = TaskRepository.draftSha256(metaPrompt);
    final startedAt = evidence['started_at'] as String;
    final finishedAt = evidence['finished_at'] as String;
    final environmentId = evidence['environment_id'] as String?;
    final common = <String, Object?>{
      'evidence_kind': evidenceKind,
      'host_invocation_id': hostInvocationId,
      'host_id': evidence['host_id'],
      'runner_id': evidence['runner_id'],
      if (environmentId case final environmentId?) ...{
        'environment_id': environmentId,
      },
      'source_revision': source.promptDraftRevision,
      'source_sha256': sourceSha256,
      'result_sha256': resultSha256,
      'result_ref': evidence['result_ref'],
      'started_at': startedAt,
      'finished_at': finishedAt,
    };
    final created = <(EntityKind, String)>[];
    WorkTask? updated;
    try {
      updated = tasks.saveMeta(source, metaPrompt);
      canonical.create(
        CanonicalEntity(
          kind: EntityKind.run,
          id: runId,
          data: {
            'schema_version': 1,
            'id': runId,
            'type': 'run',
            'task_id': taskId,
            'operation_id': operationId,
            'status': 'completed',
            'purpose': evidenceKind == 'runtime_observed'
                ? 'runtime_meta_prompt_generation'
                : 'manual_meta_prompt_generation',
            ...common,
          },
        ),
      );
      created.add((EntityKind.run, runId));
      canonical.create(
        CanonicalEntity(
          kind: EntityKind.invocation,
          id: invocationId,
          data: {
            'schema_version': 1,
            'id': invocationId,
            'type': 'skill_invocation',
            'run_id': runId,
            'skill_id': skillId,
            'round': 0,
            'sequence': 1,
            'bundle_version': evidence['bundle_version'],
            'bundle_checksum': evidence['bundle_checksum'],
            'status': 'completed',
            ...common,
          },
        ),
      );
      created.add((EntityKind.invocation, invocationId));
      canonical.create(
        CanonicalEntity(
          kind: EntityKind.event,
          id: eventId,
          data: {
            'schema_version': 1,
            'id': eventId,
            'type': 'event',
            'event_type': 'meta_prompt_generated',
            'occurred_at': finishedAt,
            'task_id': taskId,
            'run_id': runId,
            'scope': {
              'task_ids': [taskId],
              'run_ids': [runId],
            },
            ...common,
          },
        ),
      );
      created.add((EntityKind.event, eventId));
      return ManualMetaPromptRecord(
        task: updated,
        runId: runId,
        invocationId: invocationId,
        eventId: eventId,
      );
    } on Object {
      for (final entry in created.reversed) {
        final file = canonical.fileFor(entry.$1, entry.$2);
        if (file.existsSync()) file.deleteSync();
      }
      if (updated != null) tasks.update(source);
      rethrow;
    }
  }

  void _validateEvidence(
    WorkTask source,
    String metaPrompt,
    Map<String, Object?> evidence,
  ) {
    const requiredStrings = [
      'protocol',
      'skill_id',
      'bundle_version',
      'bundle_checksum',
      'host_invocation_id',
      'host_id',
      'runner_id',
      'source_sha256',
      'started_at',
      'finished_at',
      'status',
      'result_sha256',
      'result_ref',
    ];
    for (final key in requiredStrings) {
      final value = evidence[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Evidence $key must be a non-empty string.');
      }
    }
    if (evidence['protocol'] != 'under-claw-meta-evidence/v1') {
      throw const FormatException('Unsupported Meta evidence protocol.');
    }
    if (evidence['skill_id'] != skillId) {
      throw const FormatException('Evidence must name under-claw-meta-prompt.');
    }
    if (evidence['status'] != 'completed') {
      throw const FormatException(
        'Only completed host evidence is recordable.',
      );
    }
    if (evidence['source_revision'] != source.promptDraftRevision) {
      throw const FormatException('Evidence source revision is stale.');
    }
    final sourceSha256 = TaskRepository.draftSha256(source.promptDraft);
    if (evidence['source_sha256'] != sourceSha256) {
      throw const FormatException('Evidence source SHA-256 does not match.');
    }
    if (!_sha256.hasMatch(evidence['bundle_checksum'] as String)) {
      throw const FormatException('Bundle checksum must be a SHA-256 digest.');
    }
    final resultSha256 = TaskRepository.draftSha256(metaPrompt);
    if (evidence['result_sha256'] != resultSha256) {
      throw const FormatException('Evidence result SHA-256 does not match.');
    }
    final resultRef = evidence['result_ref'] as String;
    final match = _portableResultRef.firstMatch(resultRef);
    if (match == null ||
        match.group(1) != source.id ||
        int.parse(match.group(2)!) != source.promptDraftRevision) {
      throw const FormatException('Evidence result_ref is not canonical.');
    }
    final startedAt = DateTime.tryParse(evidence['started_at'] as String);
    final finishedAt = DateTime.tryParse(evidence['finished_at'] as String);
    if (startedAt == null ||
        finishedAt == null ||
        finishedAt.isBefore(startedAt)) {
      throw const FormatException('Evidence timestamps are invalid.');
    }
    final environmentId = evidence['environment_id'];
    if (environmentId != null &&
        (environmentId is! String ||
            !RegExp(r'^ENV-[A-Za-z0-9_-]+$').hasMatch(environmentId))) {
      throw const FormatException('Evidence environment_id is invalid.');
    }
  }
}
