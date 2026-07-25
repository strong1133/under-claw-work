import 'canonical_repository.dart';
import 'task_repository.dart';
import 'workspace.dart';

class RelationContract {
  const RelationContract({
    required this.name,
    required this.sources,
    required this.targets,
    this.maximum,
    this.inverse,
  });

  final String name;
  final Set<EntityKind> sources;
  final Set<EntityKind> targets;
  final int? maximum;
  final String? inverse;
}

class RelationRegistry {
  RelationRegistry(this.workspace)
    : repository = CanonicalRepository(workspace);

  final Workspace workspace;
  final CanonicalRepository repository;

  static final Map<String, RelationContract> contracts = {
    for (final contract in _contracts) contract.name: contract,
  };

  void validateGraph() {
    for (final task in TaskRepository(workspace).list()) {
      final file = workspace.taskRelations(task.id);
      if (!file.existsSync()) continue;
      final relations = repository.readLoose(file);
      for (final entry in relations.entries) {
        _validateTargets(EntityKind.task, task.id, entry.key, entry.value);
      }
    }
    for (final entity in repository.list()) {
      final relations = entity.data['relations'];
      if (relations is! Map) continue;
      for (final entry in relations.entries) {
        _validateTargets(
          entity.kind,
          entity.id,
          entry.key.toString(),
          entry.value,
        );
      }
    }
  }

  void _validateTargets(
    EntityKind sourceKind,
    String sourceId,
    String relation,
    Object? rawTargets,
  ) {
    final contract = contracts[relation];
    if (contract == null || !contract.sources.contains(sourceKind)) {
      throw FormatException('$sourceId uses unsupported relation "$relation".');
    }
    final targets = switch (rawTargets) {
      String value => [value],
      List values => values.whereType<String>().toList(),
      null => <String>[],
      _ => throw FormatException(
        '$sourceId relation $relation must be a list.',
      ),
    };
    if (contract.maximum != null && targets.length > contract.maximum!) {
      throw FormatException(
        '$sourceId relation $relation allows at most ${contract.maximum}.',
      );
    }
    if (targets.length != targets.toSet().length) {
      throw FormatException('$sourceId relation $relation has duplicates.');
    }
    for (final targetId in targets) {
      final targetKind = _kindForId(targetId);
      if (targetKind == null ||
          !contract.targets.contains(targetKind) ||
          !_exists(targetKind, targetId)) {
        throw FormatException(
          '$sourceId relation $relation has invalid target $targetId.',
        );
      }
      if (targetId == sourceId &&
          const {
            'blocked_by',
            'blocks',
            'supersedes',
            'depends_on',
            'follows',
            'duplicates',
            'reopens',
          }.contains(relation)) {
        throw FormatException('$sourceId cannot $relation itself.');
      }
      if (sourceKind == EntityKind.task &&
          const {
            EntityKind.objective,
            EntityKind.knowledge,
            EntityKind.reference,
          }.contains(targetKind)) {
        final task = TaskRepository(workspace).get(sourceId);
        final target = repository.get(targetKind, targetId);
        if (task == null ||
            target == null ||
            !repository
                .scopeOf(target)
                .permitsTask(
                  domainId: task.domainId,
                  milestoneId: task.milestoneId,
                  taskId: task.id,
                )) {
          throw FormatException(
            '$sourceId relation $relation has out-of-scope target $targetId.',
          );
        }
      }
    }
  }

  bool _exists(EntityKind kind, String id) => kind == EntityKind.task
      ? TaskRepository(workspace).get(id) != null
      : repository.exists(kind, id);

  EntityKind? _kindForId(String id) {
    for (final kind in EntityKind.values) {
      if (id.startsWith('${kind.prefix}-')) return kind;
    }
    return null;
  }

  static const _taskKinds = {EntityKind.task};
  static const _knowledgeKinds = {EntityKind.knowledge};
  static const _contracts = [
    RelationContract(
      name: 'objective_ids',
      sources: _taskKinds,
      targets: {EntityKind.objective},
    ),
    RelationContract(
      name: 'knowledge_ids',
      sources: _taskKinds,
      targets: _knowledgeKinds,
    ),
    RelationContract(
      name: 'reference_ids',
      sources: _taskKinds,
      targets: {EntityKind.reference},
    ),
    RelationContract(
      name: 'blocked_by',
      sources: _taskKinds,
      targets: _taskKinds,
      inverse: 'blocks',
    ),
    RelationContract(
      name: 'blocks',
      sources: _taskKinds,
      targets: _taskKinds,
      inverse: 'blocked_by',
    ),
    RelationContract(
      name: 'depends_on',
      sources: _taskKinds,
      targets: _taskKinds,
    ),
    RelationContract(
      name: 'derived_from',
      sources: {EntityKind.task, EntityKind.knowledge},
      targets: {EntityKind.task, EntityKind.knowledge, EntityKind.reference},
      maximum: 1,
    ),
    RelationContract(
      name: 'follows',
      sources: _taskKinds,
      targets: _taskKinds,
      maximum: 1,
    ),
    RelationContract(
      name: 'related_to',
      sources: _taskKinds,
      targets: _taskKinds,
    ),
    RelationContract(
      name: 'supersedes',
      sources: {EntityKind.task, EntityKind.knowledge},
      targets: {EntityKind.task, EntityKind.knowledge},
    ),
    RelationContract(
      name: 'duplicates',
      sources: _taskKinds,
      targets: _taskKinds,
      maximum: 1,
    ),
    RelationContract(
      name: 'reopens',
      sources: _taskKinds,
      targets: _taskKinds,
      maximum: 1,
    ),
    RelationContract(
      name: 'supports',
      sources: _knowledgeKinds,
      targets: _knowledgeKinds,
    ),
    RelationContract(
      name: 'contradicts',
      sources: _knowledgeKinds,
      targets: _knowledgeKinds,
    ),
  ];
}
