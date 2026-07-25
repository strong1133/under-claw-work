import 'canonical_repository.dart';
import 'id.dart';
import 'workspace.dart';

class AgentRole {
  const AgentRole({
    required this.name,
    required this.personaId,
    this.independent = false,
  });

  final String name;
  final String personaId;
  final bool independent;

  Map<String, Object?> toJson() => {
    'name': name,
    'persona_id': personaId,
    'independent': independent,
  };
}

class ScopeConfigurationService {
  ScopeConfigurationService(this.workspace)
    : repository = CanonicalRepository(workspace);

  final Workspace workspace;
  final CanonicalRepository repository;

  CanonicalEntity createFromDescriptor(
    EntityKind kind,
    Map<String, Object?> descriptor,
  ) {
    String requiredString(String key) {
      final value = descriptor[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key is required.');
      }
      return value;
    }

    String? optionalString(String key) => switch (descriptor[key]) {
      null => null,
      String value when value.trim().isNotEmpty => value,
      _ => throw FormatException('$key must be a non-empty string.'),
    };
    List<String> strings(String key) => switch (descriptor[key]) {
      List values when values.every((value) => value is String) =>
        values.cast<String>(),
      null => const [],
      _ => throw FormatException('$key must be a string list.'),
    };
    final reserved = {
      'title',
      'body',
      'domain_id',
      'milestone_id',
      'locator_kind',
      'locator_value',
      'repository_ids',
      'roles',
      'platform',
      'external_channel_id',
      'agent_group_id',
      'binding_key',
      'access',
      'ordered_skill_ids',
      'per_round_skill_id',
    };
    final extra = Map<String, Object?>.from(descriptor)
      ..removeWhere((key, _) => reserved.contains(key));
    return switch (kind) {
      EntityKind.repository => createRepository(
        title: requiredString('title'),
        locatorKind: requiredString('locator_kind'),
        locatorValue: requiredString('locator_value'),
        extra: extra,
      ),
      EntityKind.project => createProject(
        title: requiredString('title'),
        domainId: requiredString('domain_id'),
        milestoneId: optionalString('milestone_id'),
        repositoryIds: strings('repository_ids'),
        extra: extra,
      ),
      EntityKind.persona => createPersona(
        title: requiredString('title'),
        body: optionalString('body') ?? '',
        domainId: requiredString('domain_id'),
        milestoneId: optionalString('milestone_id'),
        extra: extra,
      ),
      EntityKind.agentGroup => createAgentGroup(
        title: requiredString('title'),
        domainId: requiredString('domain_id'),
        milestoneId: optionalString('milestone_id'),
        roles: switch (descriptor['roles']) {
          List values when values.every((value) => value is Map) =>
            values.cast<Map>().map((role) {
              final name = role['name'];
              final personaId = role['persona_id'];
              final independent = role['independent'];
              if (name is! String || personaId is! String) {
                throw const FormatException(
                  'Each role requires name and persona_id.',
                );
              }
              if (independent != null && independent is! bool) {
                throw const FormatException('independent must be a boolean.');
              }
              return AgentRole(
                name: name,
                personaId: personaId,
                independent: independent == true,
              );
            }).toList(),
          _ => throw const FormatException('roles must be a list.'),
        },
        extra: extra,
      ),
      EntityKind.channelBinding => createChannelBinding(
        title: requiredString('title'),
        platform: requiredString('platform'),
        externalChannelId: requiredString('external_channel_id'),
        domainId: requiredString('domain_id'),
        milestoneId: optionalString('milestone_id'),
        agentGroupId: requiredString('agent_group_id'),
        extra: extra,
      ),
      EntityKind.mcpBinding => createMcpBinding(
        title: requiredString('title'),
        bindingKey: requiredString('binding_key'),
        access: requiredString('access'),
        domainId: requiredString('domain_id'),
        milestoneId: optionalString('milestone_id'),
        extra: extra,
      ),
      EntityKind.skillPolicy => createSkillPolicy(
        title: requiredString('title'),
        orderedSkillIds: strings('ordered_skill_ids'),
        perRoundSkillId: optionalString('per_round_skill_id'),
        domainId: requiredString('domain_id'),
        milestoneId: optionalString('milestone_id'),
        extra: extra,
      ),
      _ => throw FormatException('${kind.type} is not a scope configuration.'),
    };
  }

  CanonicalEntity createRepository({
    required String title,
    required String locatorKind,
    required String locatorValue,
    Map<String, Object?> extra = const {},
  }) {
    final locator = locatorValue.trim();
    final uri = Uri.tryParse(locator);
    final isWindowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(locator);
    final isLocal =
        locatorKind == 'local_path' ||
        locator.startsWith('/') ||
        isWindowsAbsolute ||
        uri?.scheme == 'file';
    final hasEmbeddedCredential =
        uri != null &&
        uri.userInfo.isNotEmpty &&
        (const {'http', 'https'}.contains(uri.scheme) ||
            Uri.decodeComponent(uri.userInfo).contains(':'));
    final hasCredentialQuery =
        uri != null &&
        uri.queryParameters.keys.any((key) {
          final normalized = key.toLowerCase();
          return _forbiddenKeys.any(normalized.contains);
        });
    if (isLocal) {
      throw const FormatException(
        'Repository local paths belong in environment-local bindings.',
      );
    }
    if (hasEmbeddedCredential || hasCredentialQuery) {
      throw const FormatException(
        'Repository locators must not contain embedded credentials.',
      );
    }
    return _create(
      EntityKind.repository,
      title,
      extra: {
        ...extra,
        'locator': {'kind': locatorKind, 'value': locator},
      },
    );
  }

  CanonicalEntity createProject({
    required String title,
    required String domainId,
    List<String> repositoryIds = const [],
    String? milestoneId,
    Map<String, Object?> extra = const {},
  }) => _create(
    EntityKind.project,
    title,
    domainId: domainId,
    milestoneId: milestoneId,
    extra: {...extra, 'repository_ids': repositoryIds},
  );

  CanonicalEntity createPersona({
    required String title,
    required String body,
    required String domainId,
    String? milestoneId,
    Map<String, Object?> extra = const {},
  }) => _create(
    EntityKind.persona,
    title,
    body: body,
    domainId: domainId,
    milestoneId: milestoneId,
    extra: extra,
  );

  CanonicalEntity createAgentGroup({
    required String title,
    required String domainId,
    required List<AgentRole> roles,
    String? milestoneId,
    Map<String, Object?> extra = const {},
  }) => _create(
    EntityKind.agentGroup,
    title,
    domainId: domainId,
    milestoneId: milestoneId,
    extra: {...extra, 'roles': roles.map((role) => role.toJson()).toList()},
  );

  CanonicalEntity createChannelBinding({
    required String title,
    required String platform,
    required String externalChannelId,
    required String domainId,
    required String agentGroupId,
    String? milestoneId,
    Map<String, Object?> extra = const {},
  }) {
    final duplicate = repository
        .list(EntityKind.channelBinding)
        .any(
          (entity) =>
              entity.data['status'] == 'active' &&
              entity.data['platform'] == platform &&
              entity.data['external_channel_id'] == externalChannelId,
        );
    if (duplicate) {
      throw StateError('The external channel is already bound.');
    }
    return _create(
      EntityKind.channelBinding,
      title,
      domainId: domainId,
      milestoneId: milestoneId,
      extra: {
        ...extra,
        'platform': platform,
        'external_channel_id': externalChannelId,
        'agent_group_id': agentGroupId,
      },
    );
  }

  CanonicalEntity createMcpBinding({
    required String title,
    required String bindingKey,
    required String access,
    required String domainId,
    String? milestoneId,
    Map<String, Object?> extra = const {},
  }) {
    final duplicate = repository
        .list(EntityKind.mcpBinding)
        .any(
          (entity) =>
              entity.data['status'] == 'active' &&
              entity.data['binding_key'] == bindingKey &&
              _sameScope(entity, domainId, milestoneId),
        );
    if (duplicate) {
      throw StateError('The MCP binding key already exists in this scope.');
    }
    return _create(
      EntityKind.mcpBinding,
      title,
      domainId: domainId,
      milestoneId: milestoneId,
      extra: {...extra, 'binding_key': bindingKey, 'access': access},
    );
  }

  CanonicalEntity createSkillPolicy({
    required String title,
    required List<String> orderedSkillIds,
    required String domainId,
    String? perRoundSkillId,
    String? milestoneId,
    Map<String, Object?> extra = const {},
  }) {
    final duplicate = repository
        .list(EntityKind.skillPolicy)
        .any(
          (entity) =>
              entity.data['status'] == 'active' &&
              _sameScope(entity, domainId, milestoneId),
        );
    if (duplicate) {
      throw StateError('A Skill Policy already exists for this exact scope.');
    }
    return _create(
      EntityKind.skillPolicy,
      title,
      domainId: domainId,
      milestoneId: milestoneId,
      extra: {
        ...extra,
        'ordered_skill_ids': orderedSkillIds,
        'per_round_skill_id': ?perRoundSkillId,
      },
    );
  }

  bool _sameScope(
    CanonicalEntity entity,
    String domainId,
    String? milestoneId,
  ) {
    final scope = entity.data['scope'];
    final configuredDomain = scope is Map
        ? scope['domain_id']
        : entity.data['domain_id'];
    final configuredMilestone = scope is Map
        ? scope['milestone_id']
        : entity.data['milestone_id'];
    return configuredDomain == domainId && configuredMilestone == milestoneId;
  }

  CanonicalEntity _create(
    EntityKind kind,
    String title, {
    String body = '',
    String? domainId,
    String? milestoneId,
    Map<String, Object?> extra = const {},
  }) {
    if (title.trim().isEmpty) throw const FormatException('Title is required.');
    final metadata = Map<String, Object?>.from(extra)
      ..removeWhere((key, _) => _reservedCanonicalFields.contains(key));
    _rejectLocalOrSecretData(metadata);
    final now = DateTime.now().toUtc().toIso8601String();
    final id = newId(kind.prefix);
    final scope = <String, Object?>{
      'domain_id': ?domainId,
      'milestone_id': ?milestoneId,
    };
    return repository.create(
      CanonicalEntity(
        kind: kind,
        id: id,
        data: {
          ...metadata,
          'schema_version': 1,
          'id': id,
          'type': kind.type,
          'title': title.trim(),
          'status': 'active',
          if (scope.isNotEmpty) 'scope': scope,
          'domain_id': ?domainId,
          'milestone_id': ?milestoneId,
          'created_at': now,
          'updated_at': now,
        },
        body: body,
      ),
    );
  }

  void _rejectLocalOrSecretData(Object? value, [String path = 'extra']) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        if (_forbiddenKeys.any(key.contains)) {
          throw FormatException('$path.${entry.key} is local or secret data.');
        }
        _rejectLocalOrSecretData(entry.value, '$path.${entry.key}');
      }
    } else if (value is List) {
      for (var index = 0; index < value.length; index++) {
        _rejectLocalOrSecretData(value[index], '$path[$index]');
      }
    }
  }

  static const _forbiddenKeys = [
    'token',
    'secret',
    'password',
    'credential',
    'authorization',
    'api_key',
    'local_path',
  ];

  static const _reservedCanonicalFields = {
    'schema_version',
    'id',
    'type',
    'title',
    'status',
    'scope',
    'domain_id',
    'milestone_id',
    'created_at',
    'updated_at',
  };
}
