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
      case EntityKind.project:
        _configurationScope(entity);
        _nonEmpty(entity, 'title');
        _configurationStatus(entity);
        _stringList(entity, 'repository_ids', prefix: 'REP-');
      case EntityKind.repository:
        _nonEmpty(entity, 'title');
        _configurationStatus(entity);
        final locator = _map(entity, 'locator');
        _nestedNonEmpty(entity, locator, 'locator.kind', 'kind');
        _nestedNonEmpty(entity, locator, 'locator.value', 'value');
        _repositoryLocator(entity, locator);
      case EntityKind.persona:
        _configurationScope(entity);
        _nonEmpty(entity, 'title');
        _configurationStatus(entity);
      case EntityKind.agentGroup:
        _configurationScope(entity);
        _nonEmpty(entity, 'title');
        _configurationStatus(entity);
        final roles = _list(entity, 'roles');
        if (roles.isEmpty) {
          throw ContractViolation(entity.id, 'roles', 'must not be empty');
        }
        for (var index = 0; index < roles.length; index++) {
          final role = roles[index];
          if (role is! Map ||
              role.keys.any(
                (key) =>
                    !const {'name', 'persona_id', 'independent'}.contains(key),
              )) {
            throw ContractViolation(
              entity.id,
              'roles[$index]',
              'must be a role object with no additional properties',
            );
          }
          _nestedNonEmpty(entity, role, 'roles[$index].name', 'name');
          _nestedId(
            entity,
            role,
            'roles[$index].persona_id',
            'persona_id',
            'PER-',
          );
          if (role['independent'] is! bool) {
            throw ContractViolation(
              entity.id,
              'roles[$index].independent',
              'must be a boolean',
            );
          }
        }
      case EntityKind.channelBinding:
        _configurationScope(entity);
        _nonEmpty(entity, 'title');
        _equals(entity, 'platform', 'discord');
        _nonEmpty(entity, 'external_channel_id');
        _id(entity, 'agent_group_id', 'AGG-');
        _configurationStatus(entity);
      case EntityKind.mcpBinding:
        _configurationScope(entity);
        _nonEmpty(entity, 'title');
        _pattern(entity, 'binding_key', RegExp(r'^[A-Za-z0-9._-]+$'));
        _allowed(entity, 'access', const ['read', 'read_write']);
        _configurationStatus(entity);
      case EntityKind.skillPolicy:
        _configurationScope(entity);
        _nonEmpty(entity, 'title');
        _stringList(entity, 'ordered_skill_ids');
        if (entity.data['per_round_skill_id'] != null) {
          _nonEmpty(entity, 'per_round_skill_id');
        }
        _configurationStatus(entity);
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
      case EntityKind.match:
        _validateMatch(entity);
      case EntityKind.task:
        throw const ContractViolation(
          'task',
          'document',
          'Use validateTask for WorkTask documents.',
        );
    }
  }

  /// Runtime acceptance boundary for a Match document. Kept equivalent to the
  /// portable `match.schema.yaml`: it validates the subject/target actor
  /// internals (kind enums + id patterns), the confidence range (0..1), the
  /// append-only history entries, and the policy that agent/hybrid-produced
  /// matches must carry explainable evidence.
  void _validateMatch(CanonicalEntity entity) {
    final subject = _map(entity, 'subject');
    _nestedAllowed(entity, subject, 'subject.kind', 'kind', const [
      'knowledge',
      'reference',
    ]);
    _nestedPattern(entity, subject, 'subject.id', 'id', _matchSubjectId);
    final target = _map(entity, 'target');
    _nestedAllowed(entity, target, 'target.kind', 'kind', const [
      'domain',
      'milestone',
      'objective',
      'task',
    ]);
    _nestedPattern(entity, target, 'target.id', 'id', _matchTargetId);

    final mode = entity.data['match_mode'];
    _allowed(entity, 'match_mode', const ['manual', 'agent', 'hybrid']);
    _allowed(entity, 'review_state', const [
      'proposed',
      'approved',
      'rejected',
      'revoked',
    ]);

    final actor = _map(entity, 'actor');
    _nestedAllowed(entity, actor, 'actor.actor_type', 'actor_type', const [
      'user',
      'agent',
    ]);
    _nestedNonEmpty(entity, actor, 'actor.actor_id', 'actor_id');

    final confidence = entity.data['confidence'];
    if (confidence != null) {
      if (confidence is! num || confidence < 0 || confidence > 1) {
        throw ContractViolation(
          entity.id,
          'confidence',
          'must be a number between 0 and 1',
        );
      }
    }

    // Explainability policy: agent- and hybrid-produced candidates must record
    // evidence so an automated match is never opaque.
    if (mode == 'agent' || mode == 'hybrid') {
      final evidence = entity.data['evidence'];
      if (evidence is! String || evidence.trim().isEmpty) {
        throw ContractViolation(
          entity.id,
          'evidence',
          'is required for $mode-produced matches',
        );
      }
    }

    final history = entity.data['history'];
    if (history is! List || history.isEmpty) {
      throw ContractViolation(
        entity.id,
        'history',
        'must be a non-empty append-only list',
      );
    }
    for (final raw in history) {
      if (raw is! Map) {
        throw ContractViolation(
          entity.id,
          'history',
          'entries must be objects',
        );
      }
      // g7(a): actor_type is now a required, enumerated audit field on every
      // history entry — an anonymous or spoofed-role transition is rejected.
      for (final field in const [
        'state',
        'action',
        'actor_type',
        'actor_id',
        'at',
      ]) {
        final value = raw[field];
        if (value is! String || value.trim().isEmpty) {
          throw ContractViolation(
            entity.id,
            'history.$field',
            'must be a non-empty string',
          );
        }
      }
      if (!const {'user', 'agent'}.contains(raw['actor_type'])) {
        throw ContractViolation(
          entity.id,
          'history.actor_type',
          'must be one of user, agent',
        );
      }
      if (!const {
        'proposed',
        'approved',
        'rejected',
        'revoked',
      }.contains(raw['state'])) {
        throw ContractViolation(
          entity.id,
          'history.state',
          'unsupported review state ${raw['state']}',
        );
      }
    }

    // g7(b): the top-level review_state must equal the state of the last
    // (most recent) append-only history entry — the projection can never drift
    // from the audit trail.
    final lastState = (history.last as Map)['state'];
    if (entity.data['review_state'] != lastState) {
      throw ContractViolation(
        entity.id,
        'review_state',
        'must equal the last history state ($lastState)',
      );
    }

    // g7(c): the subject/target must be mirrored consistently into the
    // canonical relation fields that give referential integrity. A match whose
    // subject/target disagree with its relation mirror is rejected, so the two
    // representations can never diverge.
    _requireMirror(entity, subject, 'subject');
    _requireMirror(entity, target, 'target');
  }

  /// Verifies that a match's subject/target block is faithfully mirrored into
  /// the canonical relation field the repository indexes for integrity.
  void _requireMirror(
    CanonicalEntity entity,
    Map<Object?, Object?> side,
    String label,
  ) {
    final kind = side['kind'];
    final id = side['id'];
    final data = entity.data;
    List<String> asIds(Object? value) => switch (value) {
      String single => [single],
      List list => list.whereType<String>().toList(),
      _ => const [],
    };
    final scope = data['scope'];
    final scopeTasks = scope is Map
        ? asIds(scope['task_ids'])
        : const <String>[];
    final mirrors = <String, bool>{
      'knowledge': asIds(data['knowledge_ids']).contains(id),
      'reference': asIds(data['reference_ids']).contains(id),
      'domain': data['domain_id'] == id,
      'milestone': data['milestone_id'] == id,
      'objective': asIds(data['objective_ids']).contains(id),
      'task': scopeTasks.contains(id),
    };
    if (mirrors[kind] != true) {
      throw ContractViolation(
        entity.id,
        '$label.id',
        '$id must be mirrored into the $kind relation field',
      );
    }
  }

  static final _matchSubjectId = RegExp(r'^(KNW|REF)-[A-Za-z0-9_-]+$');
  static final _matchTargetId = RegExp(r'^(DOM|MLS|OBJ|TSK)-[A-Za-z0-9_-]+$');

  /// Runtime acceptance boundary for the environment registry records. The
  /// portable `environment.schema.yaml` is the documentation; this method is
  /// the normative gate the registry write path calls.
  void validateEnvironment(Map<String, Object?> data) {
    final id = data['id'];
    if (id is! String || !_environmentId.hasMatch(id)) {
      throw ContractViolation('$id', 'id', 'must match ENV-<id>');
    }
    if (data['type'] != 'environment') {
      throw ContractViolation(id, 'type', 'must equal environment');
    }
    final machineKey = data['machine_key'];
    if (machineKey is! String || !_machineKey.hasMatch(machineKey)) {
      throw ContractViolation(
        id,
        'machine_key',
        'must match MK-<hash> or legacy:ENV-<id>',
      );
    }
    for (final field in const ['alias', 'os', 'architecture']) {
      final value = data[field];
      if (value is! String || value.trim().isEmpty) {
        throw ContractViolation(id, field, 'must be a non-empty string');
      }
    }
    if (!const {
      'desktop',
      'server',
      'headless',
      'agent_runtime',
    }.contains(data['kind'])) {
      throw ContractViolation(id, 'kind', 'unsupported environment kind');
    }
    if (!const {'active', 'inactive', 'retired'}.contains(data['status'])) {
      throw ContractViolation(id, 'status', 'unsupported environment status');
    }
    if (data['capabilities'] is! List) {
      throw ContractViolation(id, 'capabilities', 'must be a list');
    }
  }

  /// Runtime acceptance boundary for Agent registry records, including the
  /// Environment reference by ENV id.
  void validateAgent(Map<String, Object?> data) {
    final id = data['id'];
    if (id is! String || !id.startsWith('AGT-')) {
      throw ContractViolation('$id', 'id', 'must use AGT- prefix');
    }
    if (data['type'] != 'agent') {
      throw ContractViolation(id, 'type', 'must equal agent');
    }
    for (final field in const ['name', 'kind']) {
      final value = data[field];
      if (value is! String || value.trim().isEmpty) {
        throw ContractViolation(id, field, 'must be a non-empty string');
      }
    }
    final environmentId = data['environment_id'];
    if (environmentId is! String || !_environmentId.hasMatch(environmentId)) {
      throw ContractViolation(
        id,
        'environment_id',
        'must reference an ENV- id',
      );
    }
    if (!const {'active', 'inactive', 'retired'}.contains(data['status'])) {
      throw ContractViolation(id, 'status', 'unsupported agent status');
    }
  }

  static final _environmentId = RegExp(r'^ENV-[A-Za-z0-9_-]+$');
  static final _machineKey = RegExp(
    r'^(MK-[A-Za-z0-9]+|legacy:ENV-[A-Za-z0-9_-]+)$',
  );

  void validateTask(WorkTask task, {bool allowStaleApproval = false}) {
    if (!task.id.startsWith('TSK-')) {
      throw ContractViolation(task.id, 'id', 'must use TSK- prefix');
    }
    if (task.hasDomain && !task.domainId.startsWith('DOM-')) {
      throw ContractViolation(task.id, 'domain_id', 'must use DOM- prefix');
    }
    if (task.hasMilestone && !task.milestoneId.startsWith('MLS-')) {
      throw ContractViolation(task.id, 'milestone_id', 'must use MLS- prefix');
    }
    if (task.hasMilestone && !task.hasDomain) {
      throw ContractViolation(task.id, 'milestone_id', 'requires domain_id');
    }
    if (task.title.trim().isEmpty) {
      throw ContractViolation(task.id, 'title', 'must not be empty');
    }
    if (task.promptDraftRevision < 1) {
      throw ContractViolation(task.id, 'prompt.draft_revision', 'minimum is 1');
    }
    if (!allowStaleApproval &&
        task.approval == PromptApproval.approved &&
        !task.isMetaCurrent) {
      throw ContractViolation(
        task.id,
        'prompt.approval',
        'approved Meta Prompt must match current Draft',
      );
    }
    if (task.createdAutomatically &&
        task.parentTaskId == null &&
        task.relatedTaskIds.isEmpty) {
      throw ContractViolation(
        task.id,
        'generation',
        'automatic Task requires parent or related Task',
      );
    }
  }

  void validateRepository(
    CanonicalRepository repository,
    List<WorkTask> tasks,
  ) {
    final ids = <String>{};
    final skillPolicyScopes = <String>{};
    final channelTargets = <String>{};
    final mcpScopeKeys = <String>{};
    final entities = EntityKind.values
        .where((kind) => kind != EntityKind.task)
        .expand(repository.list);
    for (final entity in entities) {
      if (!ids.add(entity.id)) {
        throw ContractViolation(entity.id, 'id', 'duplicate canonical ID');
      }
      if (entity.kind != EntityKind.task) validateEntity(entity);
      final scope = entity.data['scope'];
      final scopeDomain = scope is Map
          ? scope['domain_id']
          : entity.data['domain_id'];
      final scopeMilestone = scope is Map
          ? scope['milestone_id']
          : entity.data['milestone_id'];
      final scopeKey = '${scopeDomain ?? ''}/${scopeMilestone ?? ''}';
      if (entity.data['status'] == 'active' &&
          entity.kind == EntityKind.skillPolicy &&
          !skillPolicyScopes.add(scopeKey)) {
        throw ContractViolation(
          entity.id,
          'scope',
          'only one Skill Policy is allowed per exact scope',
        );
      }
      if (entity.data['status'] == 'active' &&
          entity.kind == EntityKind.channelBinding) {
        final target =
            '${entity.data['platform']}/${entity.data['external_channel_id']}';
        if (!channelTargets.add(target)) {
          throw ContractViolation(
            entity.id,
            'external_channel_id',
            'external channel is already bound',
          );
        }
      }
      if (entity.data['status'] == 'active' &&
          entity.kind == EntityKind.mcpBinding) {
        final key = '$scopeKey/${entity.data['binding_key']}';
        if (!mcpScopeKeys.add(key)) {
          throw ContractViolation(
            entity.id,
            'binding_key',
            'MCP binding key must be unique in its exact scope',
          );
        }
      }
    }
    for (final task in tasks) {
      if (!ids.add(task.id)) {
        throw ContractViolation(task.id, 'id', 'duplicate canonical ID');
      }
      validateTask(task);
    }
  }

  void _status(CanonicalEntity entity) => _nonEmpty(entity, 'status');

  void _configurationStatus(CanonicalEntity entity) =>
      _allowed(entity, 'status', const ['active', 'archived']);

  void _repositoryLocator(
    CanonicalEntity entity,
    Map<Object?, Object?> locator,
  ) {
    final kind = locator['kind'] as String;
    final value = (locator['value'] as String).trim();
    if (!const {'git_remote', 'logical'}.contains(kind)) {
      throw ContractViolation(
        entity.id,
        'locator.kind',
        'must be git_remote or logical',
      );
    }
    final uri = Uri.tryParse(value);
    final isWindowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
    if (value.startsWith('/') || isWindowsAbsolute || uri?.scheme == 'file') {
      throw ContractViolation(
        entity.id,
        'locator.value',
        'local paths belong in environment-local bindings',
      );
    }
    if (uri != null &&
        uri.userInfo.isNotEmpty &&
        (const {'http', 'https'}.contains(uri.scheme) ||
            Uri.decodeComponent(uri.userInfo).contains(':'))) {
      throw ContractViolation(
        entity.id,
        'locator.value',
        'must not contain embedded credentials',
      );
    }
    const credentialKeys = {
      'token',
      'secret',
      'password',
      'credential',
      'api_key',
      'apikey',
      'access_key',
      'private_key',
    };
    final hasCredentialQuery = uri?.queryParameters.keys.any((key) {
      final normalized = key.toLowerCase();
      return credentialKeys.any(normalized.contains);
    });
    if (hasCredentialQuery ?? false) {
      throw ContractViolation(
        entity.id,
        'locator.value',
        'must not contain credential query parameters',
      );
    }
  }

  void _configurationScope(CanonicalEntity entity) {
    _id(entity, 'domain_id', 'DOM-');
    final domainId = entity.data['domain_id'];
    final milestoneId = entity.data['milestone_id'];
    if (milestoneId != null &&
        (milestoneId is! String || !milestoneId.startsWith('MLS-'))) {
      throw ContractViolation(
        entity.id,
        'milestone_id',
        'must use MLS- prefix',
      );
    }
    final rawScope = entity.data['scope'];
    if (rawScope == null) return;
    if (rawScope is! Map) {
      throw ContractViolation(entity.id, 'scope', 'must be an object');
    }
    if (rawScope['domain_id'] != domainId ||
        rawScope['milestone_id'] != milestoneId) {
      throw ContractViolation(
        entity.id,
        'scope',
        'must match top-level domain_id and milestone_id',
      );
    }
  }

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

  List<Object?> _list(CanonicalEntity entity, String field) {
    final value = entity.data[field];
    if (value is! List) {
      throw ContractViolation(entity.id, field, 'must be a list');
    }
    return value;
  }

  List<String> _stringList(
    CanonicalEntity entity,
    String field, {
    String? prefix,
  }) {
    final values = _list(entity, field);
    if (values.any(
      (value) =>
          value is! String ||
          value.trim().isEmpty ||
          (prefix != null && !value.startsWith(prefix)),
    )) {
      throw ContractViolation(
        entity.id,
        field,
        prefix == null
            ? 'must contain non-empty strings'
            : 'must contain $prefix ids',
      );
    }
    return values.cast<String>();
  }

  void _pattern(CanonicalEntity entity, String field, RegExp pattern) {
    final value = entity.data[field];
    if (value is! String || !pattern.hasMatch(value)) {
      throw ContractViolation(entity.id, field, 'has an invalid format');
    }
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

  void _nestedAllowed(
    CanonicalEntity entity,
    Map<Object?, Object?> map,
    String path,
    String key,
    List<String> values,
  ) {
    if (!values.contains(map[key])) {
      throw ContractViolation(
        entity.id,
        path,
        'must be one of ${values.join(', ')}',
      );
    }
  }

  void _nestedPattern(
    CanonicalEntity entity,
    Map<Object?, Object?> map,
    String path,
    String key,
    RegExp pattern,
  ) {
    final value = map[key];
    if (value is! String || !pattern.hasMatch(value)) {
      throw ContractViolation(entity.id, path, 'must match ${pattern.pattern}');
    }
  }
}
