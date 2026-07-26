import 'agent_registry_service.dart';
import 'canonical_repository.dart';
import 'context_builder.dart';
import 'environment_service.dart';
import 'id.dart';
import 'models.dart';
import 'relation_registry.dart';
import 'task_repository.dart';
import 'workspace.dart';

class ContextPack {
  const ContextPack({
    required this.taskId,
    required this.domain,
    required this.milestone,
    required this.objectives,
    required this.knowledge,
    required this.references,
  });

  final String taskId;
  final CanonicalEntity? domain;
  final CanonicalEntity? milestone;
  final List<CanonicalEntity> objectives;
  final List<CanonicalEntity> knowledge;
  final List<CanonicalEntity> references;
}

class EntityService {
  EntityService(this.workspace) : repository = CanonicalRepository(workspace);

  final Workspace workspace;
  final CanonicalRepository repository;

  CanonicalEntity create({
    required EntityKind kind,
    required String title,
    String body = '',
    String? domainId,
    String? milestoneId,
    String? taskId,
    String status = 'active',
    String priority = 'normal',
    List<String> objectiveIds = const [],
    List<String> knowledgeIds = const [],
    List<String> referenceIds = const [],
    Map<String, Object?> extra = const {},
  }) {
    if (!_editableKinds.contains(kind)) {
      throw FormatException('${kind.type} is not editable through this API.');
    }
    if (title.trim().isEmpty) {
      throw const FormatException('Title is required.');
    }
    if (kind == EntityKind.milestone && domainId == null) {
      throw const FormatException('Milestone requires a Domain.');
    }
    if (kind == EntityKind.objective && domainId == null) {
      throw const FormatException('Objective requires a Domain.');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final id = newId(kind.prefix);
    final scope = <String, Object?>{};
    if (domainId != null) scope['domain_id'] = domainId;
    if (milestoneId != null) scope['milestone_id'] = milestoneId;
    // Task-level scope only applies to memory entities (Knowledge/Reference):
    // it lets a fact be authored directly against a Task so cross-agent recall
    // by Task id works without needing an approved Match (requirement 3's
    // Domain/Milestone/Task scoping). Milestones/objectives never carry it.
    if (taskId != null &&
        (kind == EntityKind.knowledge || kind == EntityKind.reference)) {
      scope['task_ids'] = [taskId];
    }
    final data = <String, Object?>{
      'schema_version': 1,
      'id': id,
      'type': kind.type,
      if (kind == EntityKind.domain) 'name': title.trim(),
      'title': title.trim(),
      'status': status,
      if (kind == EntityKind.milestone ||
          kind == EntityKind.objective ||
          kind == EntityKind.knowledge ||
          kind == EntityKind.reference)
        'scope': scope,
      if (kind == EntityKind.milestone) 'domain_id': domainId,
      if (kind == EntityKind.milestone || kind == EntityKind.objective)
        'priority': priority,
      if (kind == EntityKind.domain || kind == EntityKind.milestone) ...{
        'objective_ids': objectiveIds,
        'knowledge_ids': knowledgeIds,
        'reference_ids': referenceIds,
      },
      if (kind == EntityKind.knowledge) ...{
        'kind': 'confirmed_fact',
        'confidence': 'confirmed',
        'concepts': <String>[],
        'relations': {
          'supports': <String>[],
          'contradicts': <String>[],
          'supersedes': <String>[],
          'derived_from': <String>[],
        },
        'source_refs': referenceIds,
      },
      if (kind == EntityKind.reference) ...{
        'reference_type': 'repository_document',
        'locator': {'kind': 'repo_relative_path', 'value': 'references/$id'},
        'knowledge_ids': knowledgeIds,
      },
      'created_at': now,
      'updated_at': now,
      ...extra,
    };
    return repository.create(
      CanonicalEntity(kind: kind, id: id, data: data, body: body),
    );
  }

  CanonicalEntity update(
    CanonicalEntity entity, {
    String? title,
    String? body,
    String? status,
    String? priority,
  }) {
    if (!_editableKinds.contains(entity.kind)) {
      throw FormatException('${entity.kind.type} is not editable.');
    }
    final nextTitle = title?.trim();
    if (nextTitle != null && nextTitle.isEmpty) {
      throw const FormatException('Title is required.');
    }
    final data = <String, Object?>{
      ...entity.data,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (nextTitle != null) data['title'] = nextTitle;
    if (nextTitle != null && entity.kind == EntityKind.domain) {
      data['name'] = nextTitle;
    }
    if (status != null) data['status'] = status;
    if (priority != null) data['priority'] = priority;
    return repository.update(
      CanonicalEntity(
        kind: entity.kind,
        id: entity.id,
        data: data,
        body: body ?? entity.body,
      ),
    );
  }

  CanonicalEntity archive(CanonicalEntity entity) =>
      update(entity, status: 'archived');

  CanonicalEntity link(
    CanonicalEntity source, {
    required String field,
    required EntityKind targetKind,
    required String targetId,
  }) {
    final target = repository.get(targetKind, targetId);
    if (target == null) throw StateError('Target does not exist: $targetId');
    final values = <String>{
      ...?((source.data[field] as List?)?.whereType<String>()),
      targetId,
    }.toList()..sort();
    return repository.update(
      CanonicalEntity(
        kind: source.kind,
        id: source.id,
        data: {
          ...source.data,
          field: values,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        body: source.body,
      ),
    );
  }

  void validateGraph() {
    final all = repository.list();
    final seen = <String>{};
    for (final entity in all) {
      if (!seen.add(entity.id)) {
        throw FormatException('Duplicate canonical id: ${entity.id}');
      }
      repository.validate(entity);
    }
    _validateTaskDependencyCycles();
    RelationRegistry(workspace).validateGraph();
    // Aggregate registries are validated on the same whole-graph pass so the
    // Environment/Agent contracts and the Environment ↔ Agent link are part of
    // the runtime acceptance boundary, not just portable documentation.
    EnvironmentService(workspace).validateAll();
    AgentRegistryService(workspace).validateAll();
  }

  ExecutionContextPack buildExecutionContext(
    String taskId, {
    int tokenBudget = 4096,
  }) => ContextPackBuilder(workspace).build(taskId, tokenBudget: tokenBudget);

  ContextPack buildContext(String taskId) {
    final task = TaskRepository(workspace).get(taskId);
    if (task == null) throw StateError('Task does not exist: $taskId');
    final domain = task.hasDomain
        ? repository.get(EntityKind.domain, task.domainId)
        : null;
    final milestone = task.hasMilestone
        ? repository.get(EntityKind.milestone, task.milestoneId)
        : null;
    if (task.hasDomain &&
        (domain == null || domain.data['status'] != 'active')) {
      throw StateError('Task Domain is not active: ${task.domainId}');
    }
    if (task.hasMilestone &&
        (milestone == null ||
            milestone.data['status'] != 'active' ||
            milestone.data['domain_id'] != task.domainId)) {
      throw StateError('Task Milestone is not active in its Domain.');
    }
    final entities = [
      ...repository.list(EntityKind.objective),
      ...repository.list(EntityKind.knowledge),
      ...repository.list(EntityKind.reference),
    ];
    final objectives = <CanonicalEntity>[];
    final knowledge = <CanonicalEntity>[];
    final references = <CanonicalEntity>[];
    for (final entity in entities) {
      if (entity.data['status'] == 'archived') continue;
      final scope = entity.data['scope'];
      if (!_inTaskScope(scope, task)) continue;
      switch (entity.kind) {
        case EntityKind.objective:
          objectives.add(entity);
        case EntityKind.knowledge:
          knowledge.add(entity);
        case EntityKind.reference:
          references.add(entity);
        default:
          break;
      }
    }
    return ContextPack(
      taskId: task.id,
      domain: domain,
      milestone: milestone,
      objectives: objectives,
      knowledge: knowledge,
      references: references,
    );
  }

  void _validateTaskDependencyCycles() {
    final edges = <String, Set<String>>{};
    for (final task in TaskRepository(workspace).list()) {
      final relations = workspace.taskRelations(task.id);
      if (!relations.existsSync()) continue;
      final entity = repository.readLoose(relations);
      final dependencies =
          (entity['depends_on'] as List?)?.whereType<String>().toSet() ??
          const <String>{};
      edges[task.id] = dependencies;
    }
    final visiting = <String>{};
    final visited = <String>{};
    bool visit(String id) {
      if (visiting.contains(id)) return true;
      if (!visited.add(id)) return false;
      visiting.add(id);
      for (final dependency in edges[id] ?? const <String>{}) {
        if (TaskRepository(workspace).get(dependency) == null) {
          throw FormatException('$id depends on missing $dependency.');
        }
        if (visit(dependency)) return true;
      }
      visiting.remove(id);
      return false;
    }

    for (final id in edges.keys) {
      if (visit(id)) throw const FormatException('Task dependency cycle.');
    }
  }

  bool _contains(Object? source, String key, String value) {
    if (source is! Map) return false;
    final candidate = source[key];
    return candidate is List && candidate.contains(value);
  }

  bool _inTaskScope(Object? source, WorkTask task) {
    if (source is! Map) return false;
    final taskIds = source['task_ids'];
    if (taskIds is List && taskIds.isNotEmpty) {
      return taskIds.contains(task.id);
    }
    final milestoneIds = <Object?>[
      if (source['milestone_ids'] is List) ...(source['milestone_ids'] as List),
      source['milestone_id'],
    ].where((value) => value != null).toList();
    if (milestoneIds.isNotEmpty) {
      return milestoneIds.contains(task.milestoneId);
    }
    final domainIds = source['domain_ids'];
    final hasDomainScope =
        (domainIds is List && domainIds.isNotEmpty) ||
        source['domain_id'] != null;
    if (!hasDomainScope) return true;
    return task.hasDomain &&
        (_contains(source, 'domain_ids', task.domainId) ||
            source['domain_id'] == task.domainId);
  }

  static const _editableKinds = {
    EntityKind.domain,
    EntityKind.milestone,
    EntityKind.objective,
    EntityKind.knowledge,
    EntityKind.reference,
  };
}
