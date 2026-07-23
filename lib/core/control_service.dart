import 'dart:io';

import 'canonical_repository.dart';
import 'id.dart';
import 'models.dart';
import 'projection.dart';
import 'workspace.dart';

class ControlService {
  ControlService(this.workspace, this.projection);

  final Workspace workspace;
  final ProjectionStore projection;

  String requestStart(WorkTask task, String operationId) {
    return request(task, ControlCommand.start, operationId: operationId);
  }

  String request(
    WorkTask task,
    ControlCommand command, {
    required String operationId,
    String? runId,
    String actorId = 'local-user',
  }) {
    if (command == ControlCommand.start && !task.isMetaCurrent) {
      throw StateError('Task Meta Prompt is missing, stale, or unapproved.');
    }
    if (!operationId.startsWith('OPR-')) {
      throw const FormatException('operation_id must use OPR- prefix.');
    }
    if (!_allowed[command]!.contains(task.status)) {
      throw StateError(
        '${command.name} is not valid while Task is ${task.status.name}.',
      );
    }
    if (command != ControlCommand.start && runId == null) {
      throw StateError('${command.name} requires a run id.');
    }
    final repository = CanonicalRepository(workspace);
    for (final request in repository.list(EntityKind.controlRequest)) {
      if (request.data['operation_id'] == operationId) {
        if (request.data['task_id'] != task.id) {
          throw StateError('Operation id already belongs to another task.');
        }
        if (request.data['command'] != command.name) {
          throw StateError('Operation id already belongs to another command.');
        }
        return (request.data['reserved_run_id'] ?? request.data['run_id'])
            as String;
      }
    }

    final reservedRunId = runId ?? newId('RUN');
    final requestId = newId('CTR');
    final now = DateTime.now().toUtc().toIso8601String();
    final controlSequence =
        repository
            .list(EntityKind.controlRequest)
            .where((item) => item.data['task_id'] == task.id)
            .length +
        1;
    try {
      repository.create(
        CanonicalEntity(
          kind: EntityKind.controlRequest,
          id: requestId,
          data: {
            'schema_version': 1,
            'id': requestId,
            'type': 'control_request',
            'operation_id': operationId,
            'task_id': task.id,
            'run_id': command == ControlCommand.start ? null : reservedRunId,
            'command': command.name,
            'expected_task_revision': task.promptDraftRevision,
            'control_sequence': controlSequence,
            'target_environment_id': task.targetEnvironment,
            'requested_by': {'actor_type': 'user', 'actor_id': actorId},
            'requested_from_environment_id': task.targetEnvironment,
            'idempotency_key': operationId,
            'reserved_run_id': command == ControlCommand.start
                ? reservedRunId
                : null,
            'requested_at': now,
          },
        ),
      );
    } on FileSystemException {
      for (final request in repository.list(EntityKind.controlRequest)) {
        if (request.data['operation_id'] == operationId) {
          return (request.data['reserved_run_id'] ?? request.data['run_id'])
              as String;
        }
      }
      rethrow;
    }
    if (command == ControlCommand.start &&
        repository.get(EntityKind.run, reservedRunId) == null) {
      repository.create(
        CanonicalEntity(
          kind: EntityKind.run,
          id: reservedRunId,
          data: {
            'schema_version': 1,
            'id': reservedRunId,
            'type': 'run',
            'operation_id': operationId,
            'task_id': task.id,
            'status': 'requested',
            'created_at': now,
          },
        ),
      );
    }
    projection.rebuild();
    return reservedRunId;
  }

  CanonicalEntity addDisposition(
    String requestId,
    String disposition, {
    String actorId = 'local-user',
    String? reason,
    DateTime? now,
    bool rebuildProjection = true,
  }) {
    if (!_dispositions.contains(disposition)) {
      throw FormatException('Unknown control disposition: $disposition');
    }
    final repository = CanonicalRepository(workspace);
    final request = repository.get(EntityKind.controlRequest, requestId);
    if (request == null) {
      throw StateError('Control request does not exist: $requestId');
    }
    final operationId = request.data['operation_id'] ?? 'unknown';
    final eventId = 'EVT-${requestId.substring(4)}';
    final event = CanonicalEntity(
      kind: EntityKind.controlDisposition,
      id: eventId,
      data: {
        'schema_version': 1,
        'id': eventId,
        'type': 'control_disposition',
        'event_type': 'control_disposition',
        'request_id': requestId,
        'operation_id': operationId,
        'disposition': disposition,
        'actor': {'actor_type': 'user', 'actor_id': actorId},
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
        'occurred_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
      },
    );
    try {
      repository.create(event);
    } on FileSystemException {
      throw const FormatException('DISPOSITION_EXISTS');
    }
    if (_abortsReservedStart.contains(disposition) &&
        request.data['command'] == ControlCommand.start.name) {
      final runId = request.data['reserved_run_id'] as String?;
      final run = runId == null ? null : repository.get(EntityKind.run, runId);
      if (run != null && run.data['status'] == 'requested') {
        repository.update(
          CanonicalEntity(
            kind: EntityKind.run,
            id: run.id,
            data: {
              ...run.data,
              'status': 'aborted_before_start',
              'finished_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
            },
          ),
        );
      }
    }
    if (rebuildProjection) projection.rebuild();
    return event;
  }

  CanonicalEntity withdraw(
    String requestId, {
    String actorId = 'local-user',
    String? reason,
  }) =>
      addDisposition(requestId, 'withdrawn', actorId: actorId, reason: reason);

  CanonicalEntity expire(String requestId, {DateTime? now}) => addDisposition(
    requestId,
    'expired',
    actorId: 'system',
    reason: 'Control request timed out before disposition.',
    now: now,
  );

  CanonicalEntity? dispositionFor(String requestId) {
    final id = 'EVT-${requestId.substring(4)}';
    return CanonicalRepository(
      workspace,
    ).get(EntityKind.controlDisposition, id);
  }

  static const Map<ControlCommand, Set<TaskStatus>> _allowed = {
    ControlCommand.start: {TaskStatus.ready, TaskStatus.paused},
    ControlCommand.pause: {TaskStatus.claimed, TaskStatus.running},
    ControlCommand.resume: {TaskStatus.paused},
    ControlCommand.cancel: {
      TaskStatus.ready,
      TaskStatus.claimed,
      TaskStatus.running,
      TaskStatus.paused,
      TaskStatus.blocked,
    },
    ControlCommand.complete: {TaskStatus.running, TaskStatus.blocked},
  };

  static const _dispositions = {
    'accepted',
    'rejected',
    'withdrawn',
    'expired',
    'superseded',
  };

  static const _abortsReservedStart = {
    'rejected',
    'withdrawn',
    'expired',
    'superseded',
  };
}
