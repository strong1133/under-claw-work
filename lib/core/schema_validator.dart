import 'canonical_repository.dart';
import 'models.dart';

class ContractViolation implements Exception {
  const ContractViolation(this.entityId, this.field, this.message);

  final String entityId;
  final String field;
  final String message;

  @override
  String toString() => '$entityId.$field: $message';
}

/// Validates the Worklog product contract, including rules that span fields.
///
/// This is intentionally not advertised as a general JSON Schema 2020-12
/// implementation. Schema documents remain portable documentation; this class
/// is the normative runtime acceptance boundary.
class WorklogContractValidator {
  void validateEntity(CanonicalEntity entity) {
    _equals(entity, 'schema_version', 1);
    _nonEmpty(entity, 'id');
    _equals(entity, 'id', entity.id);
    _equals(entity, 'type', entity.kind.type);
    _prefix(entity, entity.id, '${entity.kind.prefix}-');

    switch (entity.kind) {
      case EntityKind.domain:
        _nonEmpty(entity, 'name');
        _status(entity);
      case EntityKind.milestone:
        _id(entity, 'domain_id', 'DOM-');
        _nonEmpty(entity, 'title');
        _status(entity);
      case EntityKind.objective:
        final scope = _map(entity, 'scope');
        _nestedId(entity, scope, 'scope.domain_id', 'domain_id', 'DOM-');
        _nonEmpty(entity, 'title');
        _status(entity);
      case EntityKind.knowledge:
        _nonEmpty(entity, 'kind');
        _allowed(entity, 'confidence', const [
          'confirmed',
          'probable',
          'uncertain',
          'disputed',
        ]);
        _map(entity, 'scope');
      case EntityKind.reference:
        _nonEmpty(entity, 'title');
        final locator = _map(entity, 'locator');
        _nestedNonEmpty(entity, locator, 'locator.kind', 'kind');
        _nestedNonEmpty(entity, locator, 'locator.value', 'value');
      case EntityKind.event:
        _nonEmpty(entity, 'event_type');
        _nonEmpty(entity, 'occurred_at');
      case EntityKind.claim:
        _id(entity, 'task_id', 'TSK-');
        _id(entity, 'run_id', 'RUN-');
        _nonEmpty(entity, 'environment_id');
        _allowed(entity, 'status', const ['active', 'released']);
        _nonEmpty(entity, 'heartbeat_at');
        _nonEmpty(entity, 'expires_at');
      case EntityKind.run:
        _id(entity, 'task_id', 'TSK-');
        _id(entity, 'operation_id', 'OPR-');
        _status(entity);
      case EntityKind.invocation:
        _id(entity, 'run_id', 'RUN-');
        _nonEmpty(entity, 'skill_id');
        _integer(entity, 'sequence', minimum: 1);
      case EntityKind.controlRequest:
        _id(entity, 'task_id', 'TSK-');
        _id(entity, 'operation_id', 'OPR-');
        _allowed(entity, 'command', const [
          'start',
          'pause',
          'resume',
          'cancel',
          'complete',
        ]);
      case EntityKind.controlDisposition:
        _id(entity, 'request_id', 'CTR-');
        _id(entity, 'operation_id', 'OPR-');
        _allowed(entity, 'disposition', const [
          'accepted',
          'rejected',
          'withdrawn',
          'expired',
          'superseded',
        ]);
      case EntityKind.task:
        throw const ContractViolation(
          'task',
          'document',
          'Use validateTask for WorkTask documents.',
        );
    }
  }

  void validateTask(WorkTask task) {
    if (!task.id.startsWith('TSK-')) {
      throw ContractViolation(task.id, 'id', 'must use TSK- prefix');
    }
    if (!task.domainId.startsWith('DOM-')) {
      throw ContractViolation(task.id, 'domain_id', 'must use DOM- prefix');
    }
    if (!task.milestoneId.startsWith('MLS-')) {
      throw ContractViolation(task.id, 'milestone_id', 'must use MLS- prefix');
    }
    if (task.title.trim().isEmpty) {
      throw ContractViolation(task.id, 'title', 'must not be empty');
    }
    if (task.promptDraftRevision < 1) {
      throw ContractViolation(task.id, 'prompt.draft_revision', 'minimum is 1');
    }
    if (task.approval == PromptApproval.approved && !task.isMetaCurrent) {
      throw ContractViolation(
        task.id,
        'prompt.approval',
        'approved Meta Prompt must match current Draft',
      );
    }
    if (task.createdAutomatically &&
        (task.parentTaskId == null || task.alignedObjectiveIds.isEmpty)) {
      throw ContractViolation(
        task.id,
        'generation',
        'automatic Task requires parent and aligned Objective',
      );
    }
  }

  void validateRepository(
    CanonicalRepository repository,
    List<WorkTask> tasks,
  ) {
    final ids = <String>{};
    final entities = EntityKind.values
        .where((kind) => kind != EntityKind.task)
        .expand(repository.list);
    for (final entity in entities) {
      if (!ids.add(entity.id)) {
        throw ContractViolation(entity.id, 'id', 'duplicate canonical ID');
      }
      if (entity.kind != EntityKind.task) validateEntity(entity);
    }
    for (final task in tasks) {
      if (!ids.add(task.id)) {
        throw ContractViolation(task.id, 'id', 'duplicate canonical ID');
      }
      validateTask(task);
    }
  }

  void _status(CanonicalEntity entity) => _nonEmpty(entity, 'status');

  void _nonEmpty(CanonicalEntity entity, String field) {
    final value = entity.data[field];
    if (value is! String || value.trim().isEmpty) {
      throw ContractViolation(entity.id, field, 'must be a non-empty string');
    }
  }

  Map<Object?, Object?> _map(CanonicalEntity entity, String field) {
    final value = entity.data[field];
    if (value is! Map) {
      throw ContractViolation(entity.id, field, 'must be an object');
    }
    return value;
  }

  void _id(CanonicalEntity entity, String field, String prefix) {
    final value = entity.data[field];
    if (value is! String || !value.startsWith(prefix)) {
      throw ContractViolation(entity.id, field, 'must use $prefix prefix');
    }
  }

  void _prefix(CanonicalEntity entity, String value, String prefix) {
    if (!value.startsWith(prefix)) {
      throw ContractViolation(entity.id, 'id', 'must use $prefix prefix');
    }
  }

  void _equals(CanonicalEntity entity, String field, Object expected) {
    if (entity.data[field] != expected) {
      throw ContractViolation(entity.id, field, 'must equal $expected');
    }
  }

  void _allowed(CanonicalEntity entity, String field, List<String> values) {
    if (!values.contains(entity.data[field])) {
      throw ContractViolation(
        entity.id,
        field,
        'must be one of ${values.join(', ')}',
      );
    }
  }

  void _integer(CanonicalEntity entity, String field, {required int minimum}) {
    final value = entity.data[field];
    if (value is! int || value < minimum) {
      throw ContractViolation(entity.id, field, 'minimum is $minimum');
    }
  }

  void _nestedId(
    CanonicalEntity entity,
    Map<Object?, Object?> map,
    String path,
    String key,
    String prefix,
  ) {
    final value = map[key];
    if (value is! String || !value.startsWith(prefix)) {
      throw ContractViolation(entity.id, path, 'must use $prefix prefix');
    }
  }

  void _nestedNonEmpty(
    CanonicalEntity entity,
    Map<Object?, Object?> map,
    String path,
    String key,
  ) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) {
      throw ContractViolation(entity.id, path, 'must not be empty');
    }
  }
}
