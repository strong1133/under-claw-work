import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'schema_validator.dart';
import 'workspace.dart';
import 'workspace_file_system.dart';
import 'workspace_mutation_lock.dart';

enum EntityKind {
  domain('DOM', 'domain'),
  milestone('MLS', 'milestone'),
  project('PRJ', 'project'),
  repository('REP', 'repository'),
  persona('PER', 'persona'),
  agentGroup('AGG', 'agent_group'),
  channelBinding('CHB', 'channel_binding'),
  mcpBinding('MCB', 'mcp_binding'),
  skillPolicy('SKP', 'skill_policy'),
  objective('OBJ', 'objective'),
  task('TSK', 'task'),
  knowledge('KNW', 'knowledge'),
  reference('REF', 'reference'),
  event('EVT', 'event'),
  claim('CLM', 'claim'),
  run('RUN', 'run'),
  invocation('SKI', 'skill_invocation'),
  controlRequest('CTR', 'control_request'),
  controlDisposition('EVT', 'control_disposition'),
  match('MAT', 'match');

  const EntityKind(this.prefix, this.type);
  final String prefix;
  final String type;
}

class CanonicalEntity {
  const CanonicalEntity({
    required this.kind,
    required this.id,
    required this.data,
    this.body = '',
  });

  final EntityKind kind;
  final String id;
  final Map<String, Object?> data;
  final String body;
}

class CanonicalEntityScope {
  const CanonicalEntityScope({
    required this.domainIds,
    required this.milestoneIds,
    required this.taskIds,
  });

  final Set<String> domainIds;
  final Set<String> milestoneIds;
  final Set<String> taskIds;

  bool permitsTask({
    required String domainId,
    required String milestoneId,
    required String taskId,
  }) {
    if (taskIds.isNotEmpty) return taskIds.contains(taskId);
    if (milestoneIds.isNotEmpty) return milestoneIds.contains(milestoneId);
    if (domainIds.isNotEmpty) return domainIds.contains(domainId);
    return true;
  }
}

class CanonicalRepository {
  CanonicalRepository(this.workspace);

  final Workspace workspace;

  CanonicalEntity create(CanonicalEntity entity) =>
      WorkspaceMutationLock.runExclusiveSync(workspace, () => _create(entity));

  CanonicalEntity _create(CanonicalEntity entity) {
    validate(entity);
    WorklogContractValidator().validateEntity(entity);
    final file = fileFor(entity.kind, entity.id);
    WorkspaceFileSystem.createTextExclusive(
      workspace.root,
      file,
      _encode(entity),
    );
    return entity;
  }

  CanonicalEntity update(CanonicalEntity entity) =>
      WorkspaceMutationLock.runExclusiveSync(workspace, () => _update(entity));

  CanonicalEntity _update(CanonicalEntity entity) {
    validate(entity);
    WorklogContractValidator().validateEntity(entity);
    final file = fileFor(entity.kind, entity.id);
    if (!WorkspaceFileSystem.regularFileExists(workspace.root, file)) {
      throw StateError('Entity does not exist: ${entity.id}');
    }
    if (_immutableKinds.contains(entity.kind)) {
      throw StateError('${entity.kind.type} is immutable.');
    }
    if (entity.kind == EntityKind.run) {
      final existing = _read(entity.kind, file);
      final existingSnapshot = existing.data['scope_context_snapshot'];
      if (existingSnapshot != null &&
          !_deepEqual(
            existingSnapshot,
            entity.data['scope_context_snapshot'],
          )) {
        throw StateError('Run scope_context_snapshot is immutable.');
      }
    }
    WorkspaceFileSystem.atomicWriteText(workspace.root, file, _encode(entity));
    return entity;
  }

  void delete(EntityKind kind, String id) =>
      WorkspaceMutationLock.runExclusiveSync(
        workspace,
        () => _delete(kind, id),
      );

  void _delete(EntityKind kind, String id) {
    if (_immutableKinds.contains(kind)) {
      throw StateError('${kind.type} is immutable.');
    }
    final file = fileFor(kind, id);
    if (!WorkspaceFileSystem.regularFileExists(workspace.root, file)) {
      throw StateError('Entity does not exist: $id');
    }
    WorkspaceFileSystem.deleteFile(workspace.root, file);
  }

  CanonicalEntity? get(EntityKind kind, String id) {
    final file = fileFor(kind, id);
    return WorkspaceFileSystem.regularFileExists(workspace.root, file)
        ? _read(kind, file)
        : null;
  }

  bool exists(EntityKind kind, String id) =>
      WorkspaceFileSystem.regularFileExists(workspace.root, fileFor(kind, id));

  List<CanonicalEntity> list([EntityKind? only]) {
    final kinds = only == null ? EntityKind.values : [only];
    final entities = <CanonicalEntity>[];
    for (final kind in kinds) {
      final directory = _directory(kind);
      for (final file in WorkspaceFileSystem.listFiles(
        workspace.root,
        directory,
      )) {
        if (_isCanonicalFile(kind, file)) {
          entities.add(_read(kind, file));
        }
      }
    }
    entities.sort((left, right) => left.id.compareTo(right.id));
    return entities;
  }

  void validate(CanonicalEntity entity) {
    _validateId(entity.kind, entity.id);
    if (entity.data['id'] != entity.id) {
      throw FormatException('Entity id and document id differ.');
    }
    final declaredType = entity.data['type'];
    if (declaredType != null && declaredType != entity.kind.type) {
      throw FormatException('Unexpected type $declaredType for ${entity.id}.');
    }
    _validateRelations(entity);
  }

  File fileFor(EntityKind kind, String id) {
    _validateId(kind, id);
    if (kind == EntityKind.domain) {
      return File(p.join(workspace.domains.path, id, 'domain.md'));
    }
    if (kind == EntityKind.milestone) {
      return File(p.join(workspace.milestones.path, id, 'milestone.md'));
    }
    if (kind == EntityKind.task) {
      return File(p.join(workspace.tasks.path, id, 'task.yaml'));
    }
    final extension = _markdownKinds.contains(kind) ? 'md' : 'yaml';
    return File(p.join(_directory(kind).path, '$id.$extension'));
  }

  void _validateRelations(CanonicalEntity entity) {
    final references = <(EntityKind, String)>[];
    void add(EntityKind kind, Object? value) {
      if (value is String && value.isNotEmpty) references.add((kind, value));
      if (value is List) {
        for (final item in value) {
          add(kind, item);
        }
      }
    }

    add(EntityKind.domain, entity.data['domain_id']);
    add(EntityKind.milestone, entity.data['milestone_id']);
    add(EntityKind.objective, entity.data['objective_ids']);
    add(EntityKind.knowledge, entity.data['knowledge_ids']);
    add(EntityKind.reference, entity.data['reference_ids']);
    add(EntityKind.repository, entity.data['repository_ids']);
    add(EntityKind.persona, entity.data['persona_id']);
    add(EntityKind.agentGroup, entity.data['agent_group_id']);
    final roles = entity.data['roles'];
    if (roles is List) {
      for (final role in roles.whereType<Map>()) {
        add(EntityKind.persona, role['persona_id']);
      }
    }
    final scope = entity.data['scope'];
    if (scope is Map) {
      add(EntityKind.domain, scope['domain_id']);
      add(EntityKind.domain, scope['domain_ids']);
      add(EntityKind.milestone, scope['milestone_id']);
      add(EntityKind.milestone, scope['milestone_ids']);
      add(EntityKind.task, scope['task_ids']);
      add(EntityKind.run, scope['run_ids']);
    }
    final knowledgeRelations = entity.data['relations'];
    if (entity.kind == EntityKind.knowledge && knowledgeRelations is Map) {
      for (final relation in const [
        'supports',
        'contradicts',
        'derived_from',
        'supersedes',
      ]) {
        add(EntityKind.knowledge, knowledgeRelations[relation]);
      }
    }
    for (final reference in references) {
      if (reference.$2 == entity.id) continue;
      if (!exists(reference.$1, reference.$2)) {
        throw FormatException(
          '${entity.id} references missing ${reference.$2}.',
        );
      }
    }
    final entityScope = scopeOf(entity);
    if (entity.kind != EntityKind.milestone) {
      for (final milestoneId in entityScope.milestoneIds) {
        final milestone = get(EntityKind.milestone, milestoneId);
        if (milestone == null ||
            (entityScope.domainIds.isNotEmpty &&
                !entityScope.domainIds.contains(milestone.data['domain_id']))) {
          throw FormatException(
            '${entity.id} uses a Milestone outside its Domain scope.',
          );
        }
      }
    }
    if (entity.kind == EntityKind.channelBinding) {
      final agentGroupId = entity.data['agent_group_id'];
      if (agentGroupId is String) {
        _validateScopeReference(entity, EntityKind.agentGroup, agentGroupId);
      }
    }
    if (entity.kind == EntityKind.agentGroup && roles is List) {
      for (final role in roles.whereType<Map>()) {
        final personaId = role['persona_id'];
        if (personaId is String) {
          _validateScopeReference(entity, EntityKind.persona, personaId);
        }
      }
    }
    if (entity.kind == EntityKind.knowledge && knowledgeRelations is Map) {
      for (final relation in const [
        'supports',
        'contradicts',
        'derived_from',
        'supersedes',
      ]) {
        final targets = knowledgeRelations[relation];
        if (targets is List) {
          for (final targetId in targets.whereType<String>()) {
            _validateScopeReference(entity, EntityKind.knowledge, targetId);
          }
        }
      }
    }
  }

  void _validateId(EntityKind kind, String id) {
    final validId = RegExp(
      '^${RegExp.escape(kind.prefix)}-[A-Za-z0-9][A-Za-z0-9_-]*\$',
    );
    if (!validId.hasMatch(id)) {
      throw FormatException(
        '${kind.type} id must use ${kind.prefix}- followed by letters, digits, '
        'underscores, or hyphens.',
      );
    }
  }

  void _validateScopeReference(
    CanonicalEntity source,
    EntityKind targetKind,
    String targetId,
  ) {
    final target = get(targetKind, targetId);
    if (target == null) return;
    final sourceScope = scopeOf(source);
    final targetScope = scopeOf(target);
    final domainMismatch =
        targetScope.domainIds.isNotEmpty &&
        (sourceScope.domainIds.isEmpty ||
            !sourceScope.domainIds.every(targetScope.domainIds.contains));
    final milestoneMismatch =
        targetScope.milestoneIds.isNotEmpty &&
        (sourceScope.milestoneIds.isEmpty ||
            !sourceScope.milestoneIds.every(targetScope.milestoneIds.contains));
    final taskMismatch =
        targetScope.taskIds.isNotEmpty &&
        (sourceScope.taskIds.isEmpty ||
            !sourceScope.taskIds.every(targetScope.taskIds.contains));
    if (domainMismatch || milestoneMismatch || taskMismatch) {
      throw FormatException(
        '${source.id} cannot reference out-of-scope $targetId.',
      );
    }
  }

  CanonicalEntityScope scopeOf(CanonicalEntity entity) {
    final domainIds = <String>{};
    final milestoneIds = <String>{};
    final taskIds = <String>{};
    _addScopeValues(entity.data, 'domain', domainIds);
    _addScopeValues(entity.data, 'milestone', milestoneIds);
    _addScopeValues(entity.data, 'task', taskIds);
    final scope = entity.data['scope'];
    if (scope is Map) {
      _addScopeValues(scope, 'domain', domainIds);
      _addScopeValues(scope, 'milestone', milestoneIds);
      _addScopeValues(scope, 'task', taskIds);
    }
    if (entity.kind == EntityKind.domain) domainIds.add(entity.id);
    if (entity.kind == EntityKind.milestone) milestoneIds.add(entity.id);
    return CanonicalEntityScope(
      domainIds: Set.unmodifiable(domainIds),
      milestoneIds: Set.unmodifiable(milestoneIds),
      taskIds: Set.unmodifiable(taskIds),
    );
  }

  void _addScopeValues(Map values, String name, Set<String> result) {
    final singularKey = '${name}_id';
    final pluralKey = '${name}_ids';
    if (values.containsKey(singularKey)) {
      final value = values[singularKey];
      if (value is! String || value.isEmpty) {
        throw FormatException('$singularKey must be a non-empty string.');
      }
      result.add(value);
    }
    if (values.containsKey(pluralKey)) {
      final value = values[pluralKey];
      if (value is! List ||
          value.any((item) => item is! String || item.isEmpty)) {
        throw FormatException('$pluralKey must contain non-empty strings.');
      }
      result.addAll(value.cast<String>());
    }
  }

  CanonicalEntity _read(EntityKind kind, File file) {
    final content = WorkspaceFileSystem.readText(workspace.root, file);
    final parsed = _decode(content);
    final id = parsed.$1['id'];
    if (id is! String) throw FormatException('Missing id in ${file.path}.');
    final expectedId = switch (kind) {
      EntityKind.domain || EntityKind.milestone => p.basename(file.parent.path),
      EntityKind.task =>
        p.basename(file.path) == 'task.yaml'
            ? p.basename(file.parent.path)
            : p.basenameWithoutExtension(file.path),
      _ => p.basenameWithoutExtension(file.path),
    };
    if (id != expectedId) {
      throw FormatException(
        'Document id $id differs from canonical path id $expectedId.',
      );
    }
    final entity = CanonicalEntity(
      kind: kind,
      id: id,
      data: parsed.$1,
      body: parsed.$2,
    );
    validate(entity);
    if (kind != EntityKind.task) {
      WorklogContractValidator().validateEntity(entity);
    }
    return entity;
  }

  Map<String, Object?> readLoose(File file) {
    final parsed = _decode(WorkspaceFileSystem.readText(workspace.root, file));
    return parsed.$1;
  }

  bool _isCanonicalFile(EntityKind kind, File file) {
    final name = p.basename(file.path);
    final id = switch (kind) {
      EntityKind.domain when name == 'domain.md' => p.basename(
        file.parent.path,
      ),
      EntityKind.milestone when name == 'milestone.md' => p.basename(
        file.parent.path,
      ),
      EntityKind.task when name == 'task.yaml' => p.basename(file.parent.path),
      EntityKind.task when name.endsWith('.yaml') => p.basenameWithoutExtension(
        name,
      ),
      _ when name.endsWith(_markdownKinds.contains(kind) ? '.md' : '.yaml') =>
        p.basenameWithoutExtension(name),
      _ => null,
    };
    if (id == null) return false;
    try {
      return p.equals(
        p.normalize(file.absolute.path),
        p.normalize(fileFor(kind, id).absolute.path),
      );
    } on FormatException {
      return false;
    }
  }

  (Map<String, Object?>, String) _decode(String content) {
    // Git may check portable text files out with CRLF on Windows. Normalize
    // before locating Markdown frontmatter delimiters and parsing YAML.
    final normalized = content.replaceAll('\r\n', '\n');
    var yaml = normalized;
    var body = '';
    if (normalized.startsWith('---\n')) {
      final end = normalized.indexOf('\n---', 4);
      if (end < 0) throw const FormatException('Unclosed frontmatter.');
      yaml = normalized.substring(4, end);
      body = normalized.substring(end + 4).trimLeft();
    }
    final value = loadYaml(yaml);
    if (value is! YamlMap) throw const FormatException('Expected YAML map.');
    return (_plainMap(value), body);
  }

  String _encode(CanonicalEntity entity) {
    final json = const JsonEncoder.withIndent('  ').convert(entity.data);
    return _markdownKinds.contains(entity.kind)
        ? '---\n$json\n---\n${entity.body}'
        : '$json\n';
  }

  Map<String, Object?> _plainMap(YamlMap value) =>
      value.map((key, item) => MapEntry(key.toString(), _plain(item)));

  Object? _plain(Object? value) {
    if (value is YamlMap) return _plainMap(value);
    if (value is YamlList) return value.map(_plain).toList();
    return value;
  }

  Directory _directory(EntityKind kind) => switch (kind) {
    EntityKind.domain => workspace.domains,
    EntityKind.milestone => workspace.milestones,
    EntityKind.project => workspace.projects,
    EntityKind.repository => workspace.repositories,
    EntityKind.persona => workspace.personas,
    EntityKind.agentGroup => workspace.agentGroups,
    EntityKind.channelBinding => workspace.channelBindings,
    EntityKind.mcpBinding => workspace.mcpBindings,
    EntityKind.skillPolicy => workspace.skillPolicies,
    EntityKind.objective => workspace.objectives,
    EntityKind.task => workspace.tasks,
    EntityKind.knowledge => workspace.knowledge,
    EntityKind.reference => workspace.references,
    EntityKind.event => workspace.events,
    EntityKind.claim => workspace.claims,
    EntityKind.run => workspace.runs,
    EntityKind.invocation => workspace.invocations,
    EntityKind.controlRequest => workspace.controls,
    EntityKind.controlDisposition => workspace.controlDispositions,
    EntityKind.match => workspace.matches,
  };

  static const _markdownKinds = {
    EntityKind.domain,
    EntityKind.milestone,
    EntityKind.project,
    EntityKind.repository,
    EntityKind.persona,
    EntityKind.agentGroup,
    EntityKind.channelBinding,
    EntityKind.mcpBinding,
    EntityKind.skillPolicy,
    EntityKind.objective,
    EntityKind.knowledge,
    EntityKind.reference,
  };

  static const _immutableKinds = {
    EntityKind.event,
    EntityKind.invocation,
    EntityKind.controlRequest,
    EntityKind.controlDisposition,
  };

  static bool _deepEqual(Object? left, Object? right) {
    if (identical(left, right)) return true;
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final entry in left.entries) {
        if (!right.containsKey(entry.key) ||
            !_deepEqual(entry.value, right[entry.key])) {
          return false;
        }
      }
      return true;
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!_deepEqual(left[index], right[index])) return false;
      }
      return true;
    }
    return left == right;
  }
}
