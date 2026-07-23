import 'dart:io';

import 'canonical_repository.dart';
import 'projection.dart';
import 'workspace.dart';

class ClaimService {
  ClaimService(this.workspace, this.projection);

  final Workspace workspace;
  final ProjectionStore projection;

  CanonicalEntity acquire({
    required String taskId,
    required String runId,
    required String environmentId,
    Duration ttl = const Duration(minutes: 5),
    DateTime? now,
  }) {
    final lockFile = File('${workspace.local.path}/claim-locks/$taskId.lock')
      ..createSync(recursive: true);
    final lock = lockFile.openSync(mode: FileMode.append);
    lock.lockSync(FileLock.exclusive);
    try {
      final instant = (now ?? DateTime.now()).toUtc();
      final repository = CanonicalRepository(workspace);
      final active = _active(repository, taskId, instant);
      if (active != null) {
        if (active.data['run_id'] == runId &&
            active.data['environment_id'] == environmentId) {
          return active;
        }
        throw StateError('Task already has an active claim: ${active.id}');
      }
      final id = 'CLM-${taskId.substring(4)}';
      final claim = CanonicalEntity(
        kind: EntityKind.claim,
        id: id,
        data: {
          'schema_version': 1,
          'id': id,
          'type': 'claim',
          'task_id': taskId,
          'run_id': runId,
          'environment_id': environmentId,
          'acquired_at': instant.toIso8601String(),
          'heartbeat_at': instant.toIso8601String(),
          'expires_at': instant.add(ttl).toIso8601String(),
          'status': 'active',
        },
      );
      final existing = repository.get(EntityKind.claim, id);
      if (existing == null) {
        repository.create(claim);
      } else {
        repository.update(claim);
      }
      projection.rebuild();
      return claim;
    } finally {
      lock.unlockSync();
      lock.closeSync();
    }
  }

  CanonicalEntity heartbeat(
    String claimId, {
    Duration ttl = const Duration(minutes: 5),
    DateTime? now,
  }) {
    final instant = (now ?? DateTime.now()).toUtc();
    final repository = CanonicalRepository(workspace);
    final current = repository.get(EntityKind.claim, claimId);
    if (current == null) throw StateError('Claim does not exist: $claimId');
    if (current.data['status'] != 'active' ||
        !DateTime.parse(
          current.data['expires_at'] as String,
        ).isAfter(instant)) {
      throw StateError('Claim is no longer active.');
    }
    final next = CanonicalEntity(
      kind: EntityKind.claim,
      id: claimId,
      data: {
        ...current.data,
        'heartbeat_at': instant.toIso8601String(),
        'expires_at': instant.add(ttl).toIso8601String(),
      },
    );
    repository.update(next);
    projection.rebuild();
    return next;
  }

  void release(String claimId, {DateTime? now}) {
    final repository = CanonicalRepository(workspace);
    final current = repository.get(EntityKind.claim, claimId);
    if (current == null) throw StateError('Claim does not exist: $claimId');
    repository.update(
      CanonicalEntity(
        kind: EntityKind.claim,
        id: claimId,
        data: {
          ...current.data,
          'status': 'released',
          'released_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
        },
      ),
    );
    projection.rebuild();
  }

  CanonicalEntity? _active(
    CanonicalRepository repository,
    String taskId,
    DateTime instant,
  ) {
    for (final claim in repository.list(EntityKind.claim)) {
      if (claim.data['task_id'] == taskId &&
          claim.data['status'] == 'active' &&
          DateTime.parse(claim.data['expires_at'] as String).isAfter(instant)) {
        return claim;
      }
    }
    return null;
  }
}
