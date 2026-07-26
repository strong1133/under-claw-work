import 'dart:math' as math;

import 'canonical_repository.dart';
import 'memory_recall_service.dart';
import 'task_repository.dart';
import 'workspace.dart';

class ContextEntry {
  const ContextEntry({
    required this.id,
    required this.entityType,
    required this.content,
    required this.provenance,
    required this.relationDistance,
    required this.estimatedTokens,
    this.contradictionIds = const [],
    this.truncated = false,
  });

  final String id;
  final String entityType;
  final String content;
  final String provenance;
  final int relationDistance;
  final int estimatedTokens;
  final List<String> contradictionIds;
  final bool truncated;
}

class ExecutionContextPack {
  const ExecutionContextPack({
    required this.taskId,
    required this.tokenBudget,
    required this.estimatedTokens,
    required this.entries,
    required this.omittedIds,
    required this.supersededIds,
  });

  final String taskId;
  final int tokenBudget;
  final int estimatedTokens;
  final List<ContextEntry> entries;
  final List<String> omittedIds;
  final List<String> supersededIds;
}

class ContextPackBuilder {
  ContextPackBuilder(this.workspace)
    : repository = CanonicalRepository(workspace),
      tasks = TaskRepository(workspace);

  final Workspace workspace;
  final CanonicalRepository repository;
  final TaskRepository tasks;

  ExecutionContextPack build(String taskId, {int tokenBudget = 4096}) {
    if (tokenBudget < 1) {
      throw const FormatException('Context token budget must be positive.');
    }
    final task = tasks.get(taskId);
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
    final relations = workspace.taskRelations(task.id).existsSync()
        ? repository.readLoose(workspace.taskRelations(task.id))
        : const <String, Object?>{};
    final directIds = <String>{
      ..._ids(relations['objective_ids']),
      ..._ids(relations['knowledge_ids']),
      ..._ids(relations['reference_ids']),
    };

    final candidates = <_Candidate>[
      _Candidate(
        id: task.id,
        type: 'prompt_meta',
        content: task.promptMeta,
        provenance: 'task.approved_meta',
        distance: 0,
        sectionOrder: 3,
        importance: 100,
        updatedAt: '',
      ),
    ];
    if (domain != null) candidates.add(_fromEntity(domain, 'task.domain', 0));
    if (milestone != null) {
      candidates.add(_fromEntity(milestone, 'task.milestone', 0));
    }
    for (final projectId in task.projectIds) {
      final project = repository.get(EntityKind.project, projectId);
      if (project != null && project.data['status'] == 'active') {
        candidates.add(_fromEntity(project, 'task.project', 0));
      }
    }
    for (final relation in <(String, String?)>[
      ('task.parent', task.parentTaskId),
      ...task.relatedTaskIds.map((id) => ('task.related', id)),
    ]) {
      final related = relation.$2 == null ? null : tasks.get(relation.$2!);
      if (related == null) continue;
      candidates.add(
        _Candidate(
          id: related.id,
          type: 'task',
          content:
              '${related.title}\n${related.isMetaCurrent ? related.promptMeta : related.promptDraft}',
          provenance: relation.$1,
          distance: 0,
          sectionOrder: 3,
          importance: 90,
          updatedAt: '',
        ),
      );
    }

    final graphEntities = [
      ...repository.list(EntityKind.objective),
      ...repository.list(EntityKind.knowledge),
      ...repository.list(EntityKind.reference),
    ].where((entity) => entity.data['status'] != 'archived').toList();
    final byId = {for (final entity in graphEntities) entity.id: entity};
    for (final entity in graphEntities) {
      // Execution context packs are assembled without an interactive auth
      // session, so restricted/secret material is never bundled into a prompt.
      if (_isRestricted(entity)) continue;
      if (directIds.contains(entity.id) &&
          _isGlobalOrInScope(
            entity,
            task.id,
            task.domainId,
            task.milestoneId,
          )) {
        candidates.add(_fromEntity(entity, 'task.relation', 0));
      } else {
        final scope = entity.data['scope'];
        final provenance = _scopeProvenance(
          scope,
          task.id,
          task.domainId,
          task.milestoneId,
        );
        if (provenance != null) {
          candidates.add(_fromEntity(entity, provenance, 1));
        }
      }
    }

    final selectedKnowledgeSeeds = candidates
        .where((item) => item.type == EntityKind.knowledge.type)
        .map((item) => item.id)
        .toSet();
    for (final seed in selectedKnowledgeSeeds) {
      final entity = byId[seed];
      final knowledgeRelations = entity?.data['relations'];
      if (knowledgeRelations is! Map) continue;
      for (final relation in ['supports', 'contradicts', 'derived_from']) {
        for (final targetId in _ids(knowledgeRelations[relation])) {
          final target = byId[targetId];
          if (target != null &&
              !_isRestricted(target) &&
              _isGlobalOrInScope(
                target,
                task.id,
                task.domainId,
                task.milestoneId,
              ) &&
              !candidates.any((candidate) => candidate.id == targetId)) {
            candidates.add(_fromEntity(target, 'knowledge.$relation:$seed', 2));
          }
        }
      }
    }

    // Cross-agent unified memory: Knowledge linked to this Task through an
    // approved provenance Match is recalled even when it was never scoped to
    // the Task directly. Restricted material stays excluded (no auth here).
    final recalled = MemoryRecallService(workspace).recall(
      domainId: task.domainId,
      milestoneId: task.milestoneId,
      taskId: task.id,
    );
    for (final item in recalled.current) {
      if (!item.provenance.startsWith('match:')) continue;
      final entity = byId[item.id];
      if (entity == null || _isRestricted(entity)) continue;
      if (candidates.any((candidate) => candidate.id == item.id)) continue;
      candidates.add(_fromEntity(entity, item.provenance, 1));
    }

    final supersededIds = <String>{};
    for (final entity in graphEntities.where(
      (entity) => entity.kind == EntityKind.knowledge,
    )) {
      final value = entity.data['relations'];
      if (value is Map) supersededIds.addAll(_ids(value['supersedes']));
    }
    candidates.removeWhere((item) => supersededIds.contains(item.id));
    final unique = <String, _Candidate>{};
    for (final candidate in candidates) {
      final current = unique[candidate.id];
      if (current == null || candidate.distance < current.distance) {
        unique[candidate.id] = candidate;
      }
    }
    final ordered = unique.values.toList()..sort(_compare);

    final entries = <ContextEntry>[];
    final omitted = <String>[];
    var used = 0;
    for (final candidate in ordered) {
      final remaining = tokenBudget - used;
      if (remaining <= 0) {
        omitted.add(candidate.id);
        continue;
      }
      final fullTokens = _estimateTokens(candidate.content);
      final required = candidate.distance == 0;
      if (fullTokens > remaining && !required) {
        omitted.add(candidate.id);
        continue;
      }
      final content = fullTokens <= remaining
          ? candidate.content
          : _truncate(candidate.content, remaining);
      final tokens = math.min(remaining, _estimateTokens(content));
      final contradictionIds = candidate.type == EntityKind.knowledge.type
          ? _contradictions(candidate.id, byId)
          : const <String>[];
      entries.add(
        ContextEntry(
          id: candidate.id,
          entityType: candidate.type,
          content: content,
          provenance: candidate.provenance,
          relationDistance: candidate.distance,
          estimatedTokens: tokens,
          contradictionIds: contradictionIds,
          truncated: content != candidate.content,
        ),
      );
      used += tokens;
    }
    return ExecutionContextPack(
      taskId: taskId,
      tokenBudget: tokenBudget,
      estimatedTokens: used,
      entries: entries,
      omittedIds: omitted..sort(),
      supersededIds: supersededIds.toList()..sort(),
    );
  }

  _Candidate _fromEntity(
    CanonicalEntity entity,
    String provenance,
    int distance,
  ) {
    final title = entity.data['title'] ?? entity.data['name'] ?? entity.id;
    return _Candidate(
      id: entity.id,
      type: entity.kind.type,
      content: '$title\n${entity.body}'.trim(),
      provenance: provenance,
      distance: distance,
      sectionOrder: switch (entity.kind) {
        EntityKind.domain => 0,
        EntityKind.milestone => 1,
        EntityKind.objective => 2,
        EntityKind.knowledge => 4,
        EntityKind.reference => 5,
        _ => 6,
      },
      importance: (entity.data['importance'] as num?)?.toInt() ?? 50,
      updatedAt: entity.data['updated_at']?.toString() ?? '',
    );
  }

  String? _scopeProvenance(
    Object? raw,
    String taskId,
    String domainId,
    String milestoneId,
  ) {
    if (raw is! Map) return null;
    final taskIds = _ids(raw['task_ids']);
    if (taskIds.isNotEmpty) {
      return taskIds.contains(taskId) ? 'scope.task' : null;
    }
    final milestoneIds = <String>{
      ..._ids(raw['milestone_ids']),
      if (raw['milestone_id'] case final String id) id,
    };
    if (milestoneIds.isNotEmpty) {
      return milestoneIds.contains(milestoneId) ? 'scope.milestone' : null;
    }
    if (_ids(raw['domain_ids']).contains(domainId) ||
        raw['domain_id'] == domainId) {
      return 'scope.domain';
    }
    return null;
  }

  bool _isGlobalOrInScope(
    CanonicalEntity entity,
    String taskId,
    String domainId,
    String milestoneId,
  ) {
    return repository
        .scopeOf(entity)
        .permitsTask(
          domainId: domainId,
          milestoneId: milestoneId,
          taskId: taskId,
        );
  }

  List<String> _contradictions(String id, Map<String, CanonicalEntity> byId) {
    final result = <String>{
      ..._ids((byId[id]?.data['relations'] as Map?)?['contradicts']),
    };
    for (final entity in byId.values) {
      final relations = entity.data['relations'];
      if (relations is Map && _ids(relations['contradicts']).contains(id)) {
        result.add(entity.id);
      }
    }
    return result.toList()..sort();
  }

  int _compare(_Candidate left, _Candidate right) {
    var value = left.sectionOrder.compareTo(right.sectionOrder);
    if (value != 0) return value;
    value = left.distance.compareTo(right.distance);
    if (value != 0) return value;
    value = right.importance.compareTo(left.importance);
    if (value != 0) return value;
    value = right.updatedAt.compareTo(left.updatedAt);
    if (value != 0) return value;
    return left.id.compareTo(right.id);
  }

  static bool _isRestricted(CanonicalEntity entity) {
    final visibility = entity.data['visibility'];
    return visibility == 'restricted' || visibility == 'secret';
  }

  static List<String> _ids(Object? value) => switch (value) {
    String item => [item],
    List items => items.whereType<String>().toList(),
    _ => const [],
  };

  static int _estimateTokens(String content) =>
      math.max(1, (content.runes.length / 4).ceil());

  static String _truncate(String content, int tokens) {
    if (tokens < 1) return '';
    final runes = content.runes.toList();
    final length = math.min(runes.length, tokens * 4);
    return String.fromCharCodes(runes.take(length));
  }
}

class _Candidate {
  const _Candidate({
    required this.id,
    required this.type,
    required this.content,
    required this.provenance,
    required this.distance,
    required this.sectionOrder,
    required this.importance,
    required this.updatedAt,
  });

  final String id;
  final String type;
  final String content;
  final String provenance;
  final int distance;
  final int sectionOrder;
  final int importance;
  final String updatedAt;
}
