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
    if (!task.isMetaCurrent) {
      throw StateError('Task Meta Prompt is missing, stale, or unapproved.');
    }
    final repository = CanonicalRepository(workspace);
    for (final request in repository.list(EntityKind.controlRequest)) {
      if (request.data['operation_id'] == operationId) {
        if (request.data['task_id'] != task.id) {
          throw StateError('Operation id already belongs to another task.');
        }
        return request.data['reserved_run_id']! as String;
      }
    }

    final runId = newId('RUN');
    final requestId = newId('CTR');
    final now = DateTime.now().toUtc().toIso8601String();
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
            'run_id': null,
            'command': 'start',
            'expected_task_revision': task.promptDraftRevision,
            'target_environment_id': task.targetEnvironment,
            'requested_by': {'actor_type': 'user', 'actor_id': 'local-user'},
            'requested_from_environment_id': task.targetEnvironment,
            'idempotency_key': operationId,
            'reserved_run_id': runId,
            'requested_at': now,
          },
        ),
      );
    } on FileSystemException {
      for (final request in repository.list(EntityKind.controlRequest)) {
        if (request.data['operation_id'] == operationId) {
          return request.data['reserved_run_id']! as String;
        }
      }
      rethrow;
    }
    repository.create(
      CanonicalEntity(
        kind: EntityKind.run,
        id: runId,
        data: {
          'schema_version': 1,
          'id': runId,
          'type': 'run',
          'operation_id': operationId,
          'task_id': task.id,
          'status': 'requested',
          'created_at': now,
        },
      ),
    );
    projection.rebuild();
    return runId;
  }

  void addDisposition(String requestId, String disposition) {
    final repository = CanonicalRepository(workspace);
    if (repository
        .list(EntityKind.controlDisposition)
        .any((item) => item.data['request_id'] == requestId)) {
      throw const FormatException('DISPOSITION_EXISTS');
    }
    final request = repository.get(EntityKind.controlRequest, requestId);
    final operationId = request?.data['operation_id'] ?? 'unknown';
    final eventId = newId('EVT');
    repository.create(
      CanonicalEntity(
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
          'occurred_at': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
    projection.rebuild();
  }
}
