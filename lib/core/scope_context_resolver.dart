import 'canonical_repository.dart';
import 'models.dart';
import 'workspace.dart';
import 'workspace_mutation_lock.dart';

T withRunScopeContextSnapshot<T>(
  Workspace workspace, {
  WorkTask? task,
  String? domainId,
  String? milestoneId,
  required T Function(Map<String, Object?> snapshot) persist,
}) => WorkspaceMutationLock.runExclusiveSync(workspace, () {
  final snapshot = buildRunScopeContextSnapshot(
    workspace,
    task: task,
    domainId: domainId,
    milestoneId: milestoneId,
  );
  return persist(snapshot);
});

Map<String, Object?> buildRunScopeContextSnapshot(
  Workspace workspace, {
  WorkTask? task,
  String? domainId,
  String? milestoneId,
}) {
  final repository = CanonicalRepository(workspace);
  final resolvedDomainId = task?.domainId ?? domainId ?? '';
  final resolvedMilestoneId = task == null
      ? milestoneId
      : task.hasMilestone
      ? task.milestoneId
      : null;
  if (resolvedDomainId.isEmpty) {
    if (resolvedMilestoneId != null && resolvedMilestoneId.isNotEmpty) {
      throw StateError('A Run Milestone requires a Domain.');
    }
    return _unscopedSnapshot(repository, task);
  }
  final domain = repository.get(EntityKind.domain, resolvedDomainId);
  final milestone = resolvedMilestoneId == null
      ? null
      : repository.get(EntityKind.milestone, resolvedMilestoneId);
  if (resolvedMilestoneId == null && domain == null) {
    return {
      'resolution_status': 'legacy_scope_ids_only',
      'domain': {'id': resolvedDomainId, 'type': 'domain'},
      'projects': <Object?>[],
      'repositories': <Object?>[],
      'personas': <Object?>[],
      'agent_groups': <Object?>[],
      'mcp_bindings': <Object?>[],
      'skill_policies': <Object?>[],
      if (task != null) 'task_configuration': _taskConfiguration(task),
    };
  }
  if ((domain == null && milestone != null) ||
      (domain != null && resolvedMilestoneId != null && milestone == null)) {
    throw StateError(
      'Domain and Milestone must either both exist or both be legacy IDs.',
    );
  }
  if (domain == null && milestone == null) {
    return {
      'resolution_status': 'legacy_scope_ids_only',
      'domain': {'id': resolvedDomainId, 'type': 'domain'},
      'milestone': {
        'id': resolvedMilestoneId,
        'type': 'milestone',
        'domain_id': resolvedDomainId,
      },
      'projects': <Object?>[],
      'repositories': <Object?>[],
      'personas': <Object?>[],
      'agent_groups': <Object?>[],
      'mcp_bindings': <Object?>[],
      'skill_policies': <Object?>[],
      if (task != null) 'task_configuration': _taskConfiguration(task),
    };
  }
  final snapshot = ScopeContextResolver(workspace)
      .resolve(domainId: resolvedDomainId, milestoneId: resolvedMilestoneId)
      .toJson();
  if (task != null) {
    _selectProjects(repository, snapshot, task.projectIds);
    snapshot['task_configuration'] = _taskConfiguration(task);
  }
  return snapshot;
}

Map<String, Object?> _unscopedSnapshot(
  CanonicalRepository repository,
  WorkTask? task,
) {
  final projects = task == null
      ? const <CanonicalEntity>[]
      : task.projectIds
            .map((id) => repository.get(EntityKind.project, id))
            .whereType<CanonicalEntity>()
            .toList();
  final repositoryIds = <String>{
    for (final project in projects) ..._ids(project.data['repository_ids']),
  };
  final repositories = repositoryIds
      .map((id) => repository.get(EntityKind.repository, id))
      .whereType<CanonicalEntity>()
      .toList();
  return {
    'resolution_status': 'unscoped',
    'projects': projects.map((item) => item.data).toList(),
    'repositories': repositories.map((item) => item.data).toList(),
    'personas': <Object?>[],
    'agent_groups': <Object?>[],
    'mcp_bindings': <Object?>[],
    'skill_policies': <Object?>[],
    if (task != null) 'task_configuration': _taskConfiguration(task),
  };
}

void _selectProjects(
  CanonicalRepository repository,
  Map<String, Object?> snapshot,
  List<String> projectIds,
) {
  if (projectIds.isEmpty) return;
  final projects = projectIds
      .map((id) => repository.get(EntityKind.project, id))
      .whereType<CanonicalEntity>()
      .toList();
  final repositoryIds = <String>{
    for (final project in projects) ..._ids(project.data['repository_ids']),
  };
  snapshot['projects'] = projects.map((item) => item.data).toList();
  snapshot['repositories'] = repositoryIds
      .map((id) => repository.get(EntityKind.repository, id))
      .whereType<CanonicalEntity>()
      .map((item) => item.data)
      .toList();
}

Map<String, Object?> _taskConfiguration(WorkTask task) => {
  'project_ids': task.projectIds,
  'target_environment_ids': task.effectiveTargetEnvironmentIds,
  'model_selection_keys': task.modelSelectionKeys,
  'processing_mode': task.processingMode.name,
  'parent_task_id': task.parentTaskId,
  'related_task_ids': task.relatedTaskIds,
};

List<String> _ids(Object? value) => switch (value) {
  List items => items.whereType<String>().toList(),
  String item => [item],
  _ => const [],
};

class ResolvedScopeContext {
  const ResolvedScopeContext({
    required this.domain,
    required this.milestone,
    required this.projects,
    required this.repositories,
    required this.personas,
    required this.agentGroups,
    required this.channelBinding,
    required this.mcpBindings,
    required this.skillPolicies,
    required this.selectedAgentGroup,
    required this.selectedSkillPolicy,
  });

  final CanonicalEntity domain;
  final CanonicalEntity? milestone;
  final List<CanonicalEntity> projects;
  final List<CanonicalEntity> repositories;
  final List<CanonicalEntity> personas;
  final List<CanonicalEntity> agentGroups;
  final CanonicalEntity? channelBinding;
  final List<CanonicalEntity> mcpBindings;
  final List<CanonicalEntity> skillPolicies;
  final CanonicalEntity? selectedAgentGroup;
  final CanonicalEntity? selectedSkillPolicy;

  Map<String, Object?> toJson() => {
    'domain': domain.data,
    if (milestone != null) 'milestone': milestone!.data,
    'projects': projects.map((item) => item.data).toList(),
    'repositories': repositories.map((item) => item.data).toList(),
    'personas': personas
        .map((item) => {...item.data, 'body': item.body})
        .toList(),
    'agent_groups': agentGroups.map((item) => item.data).toList(),
    if (channelBinding != null) 'channel_binding': channelBinding!.data,
    'mcp_bindings': mcpBindings.map((item) => item.data).toList(),
    'skill_policies': skillPolicies.map((item) => item.data).toList(),
    if (selectedAgentGroup != null)
      'selected_agent_group': selectedAgentGroup!.data,
    if (selectedSkillPolicy != null)
      'selected_skill_policy': selectedSkillPolicy!.data,
  };
}

class ScopeContextResolver {
  ScopeContextResolver(this.workspace)
    : repository = CanonicalRepository(workspace);

  final Workspace workspace;
  final CanonicalRepository repository;

  ResolvedScopeContext resolve({
    required String domainId,
    String? milestoneId,
    String? externalChannelId,
  }) {
    final domain = repository.get(EntityKind.domain, domainId);
    if (domain == null) throw StateError('Domain does not exist: $domainId');
    if (domain.data['status'] != 'active') {
      throw StateError('Domain is not active: $domainId');
    }
    final milestone = milestoneId == null
        ? null
        : repository.get(EntityKind.milestone, milestoneId);
    if (milestoneId != null && milestone == null) {
      throw StateError('Milestone does not exist: $milestoneId');
    }
    if (milestone != null && milestone.data['status'] != 'active') {
      throw StateError('Milestone is not active: $milestoneId');
    }
    if (milestone != null && milestone.data['domain_id'] != domainId) {
      throw FormatException('$milestoneId does not belong to $domainId.');
    }

    List<CanonicalEntity> scoped(EntityKind kind) =>
        repository
            .list(kind)
            .where(
              (entity) =>
                  entity.data['status'] == 'active' &&
                  _matchesScope(entity, domainId, milestoneId),
            )
            .toList()
          ..sort((left, right) {
            final bySpecificity = _scopeSpecificity(
              left,
            ).compareTo(_scopeSpecificity(right));
            return bySpecificity != 0
                ? bySpecificity
                : left.id.compareTo(right.id);
          });

    final projects = scoped(EntityKind.project);
    final repositoryIds = <String>{
      for (final project in projects) ..._ids(project.data['repository_ids']),
    };
    final repositories =
        repository
            .list(EntityKind.repository)
            .where(
              (entity) =>
                  entity.data['status'] == 'active' &&
                  repositoryIds.contains(entity.id),
            )
            .toList()
          ..sort((left, right) => left.id.compareTo(right.id));
    final agentGroups = scoped(EntityKind.agentGroup);
    final personaIds = <String>{};
    for (final group in agentGroups) {
      final roles = group.data['roles'];
      if (roles is! List) continue;
      for (final role in roles.whereType<Map>()) {
        final id = role['persona_id'];
        if (id is String) personaIds.add(id);
      }
    }
    final personas =
        repository
            .list(EntityKind.persona)
            .where(
              (entity) =>
                  entity.data['status'] == 'active' &&
                  (personaIds.contains(entity.id) ||
                      _matchesScope(entity, domainId, milestoneId)),
            )
            .toList()
          ..sort((left, right) => left.id.compareTo(right.id));
    final channels = scoped(EntityKind.channelBinding);
    final channel = externalChannelId == null
        ? null
        : channels
              .where(
                (item) => item.data['external_channel_id'] == externalChannelId,
              )
              .singleOrNull;
    if (externalChannelId != null && channel == null) {
      throw StateError('Channel is not bound to the requested scope.');
    }
    final skillPolicies = scoped(EntityKind.skillPolicy);
    final mcpByKey = <String, CanonicalEntity>{};
    for (final binding in scoped(EntityKind.mcpBinding)) {
      mcpByKey[binding.data['binding_key'].toString()] = binding;
    }
    final mcpBindings = mcpByKey.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    final selectedAgentGroup = channel == null
        ? agentGroups.lastOrNull
        : agentGroups
              .where(
                (group) =>
                    group.id == channel.data['agent_group_id'].toString(),
              )
              .singleOrNull;
    if (channel != null && selectedAgentGroup == null) {
      throw StateError('Channel Agent Group is not active in this scope.');
    }

    return ResolvedScopeContext(
      domain: domain,
      milestone: milestone,
      projects: projects,
      repositories: repositories,
      personas: personas,
      agentGroups: agentGroups,
      channelBinding: channel,
      mcpBindings: mcpBindings.map((entry) => entry.value).toList(),
      skillPolicies: skillPolicies,
      selectedAgentGroup: selectedAgentGroup,
      selectedSkillPolicy: skillPolicies.lastOrNull,
    );
  }

  bool _matchesScope(
    CanonicalEntity entity,
    String domainId,
    String? milestoneId,
  ) {
    final scope = _scopeOf(entity);
    if (scope['domain_id'] != domainId) return false;
    final configuredMilestone = scope['milestone_id'];
    return configuredMilestone == null || configuredMilestone == milestoneId;
  }

  int _scopeSpecificity(CanonicalEntity entity) {
    return _scopeOf(entity)['milestone_id'] != null ? 1 : 0;
  }

  Map<Object?, Object?> _scopeOf(CanonicalEntity entity) {
    final scope = entity.data['scope'];
    if (scope is Map) return scope;
    return {
      'domain_id': entity.data['domain_id'],
      'milestone_id': entity.data['milestone_id'],
    };
  }

  static List<String> _ids(Object? value) => switch (value) {
    String item => [item],
    List items => items.whereType<String>().toList(),
    _ => const [],
  };
}
