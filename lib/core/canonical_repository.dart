import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'workspace.dart';
import 'schema_validator.dart';

enum EntityKind {
  domain('DOM', 'domain'),
  milestone('MLS', 'milestone'),
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

class CanonicalRepository {
  CanonicalRepository(this.workspace);

  final Workspace workspace;

  CanonicalEntity create(CanonicalEntity entity) {
    validate(entity);
    WorklogContractValidator().validateEntity(entity);
    final file = fileFor(entity.kind, entity.id);
    file.parent.createSync(recursive: true);
    file.createSync(exclusive: true);
    file.writeAsStringSync(_encode(entity), flush: true);
    return entity;
  }

  CanonicalEntity update(CanonicalEntity entity) {
    validate(entity);
    WorklogContractValidator().validateEntity(entity);
    final file = fileFor(entity.kind, entity.id);
    if (!file.existsSync()) {
      throw StateError('Entity does not exist: ${entity.id}');
    }
    if (_immutableKinds.contains(entity.kind)) {
      throw StateError('${entity.kind.type} is immutable.');
    }
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(_encode(entity), flush: true);
    temporary.renameSync(file.path);
    return entity;
  }

  void delete(EntityKind kind, String id) {
    if (_immutableKinds.contains(kind)) {
      throw StateError('${kind.type} is immutable.');
    }
    final file = fileFor(kind, id);
    if (!file.existsSync()) {
      throw StateError('Entity does not exist: $id');
    }
    file.deleteSync();
  }

  CanonicalEntity? get(EntityKind kind, String id) {
    final file = fileFor(kind, id);
    return file.existsSync() ? _read(kind, file) : null;
  }

  bool exists(EntityKind kind, String id) => fileFor(kind, id).existsSync();

  List<CanonicalEntity> list([EntityKind? only]) {
    final kinds = only == null ? EntityKind.values : [only];
    final entities = <CanonicalEntity>[];
    for (final kind in kinds) {
      final directory = _directory(kind);
      if (!directory.existsSync()) continue;
      for (final file
          in directory.listSync(recursive: true).whereType<File>()) {
        if (_isCanonicalFile(kind, file)) {
          entities.add(_read(kind, file));
        }
      }
    }
    entities.sort((left, right) => left.id.compareTo(right.id));
    return entities;
  }

  void validate(CanonicalEntity entity) {
    if (!entity.id.startsWith('${entity.kind.prefix}-')) {
      throw FormatException(
        '${entity.kind.type} id must start with ${entity.kind.prefix}-',
      );
    }
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
    final scope = entity.data['scope'];
    if (scope is Map) {
      add(EntityKind.domain, scope['domain_id']);
      add(EntityKind.domain, scope['domain_ids']);
      add(EntityKind.milestone, scope['milestone_id']);
      add(EntityKind.milestone, scope['milestone_ids']);
      add(EntityKind.task, scope['task_ids']);
      add(EntityKind.run, scope['run_ids']);
    }
    for (final reference in references) {
      if (reference.$2 == entity.id) continue;
      if (!exists(reference.$1, reference.$2)) {
        throw FormatException(
          '${entity.id} references missing ${reference.$2}.',
        );
      }
    }
  }

  CanonicalEntity _read(EntityKind kind, File file) {
    final content = file.readAsStringSync();
    final parsed = _decode(content);
    final id = parsed.$1['id'];
    if (id is! String) throw FormatException('Missing id in ${file.path}.');
    final entity = CanonicalEntity(
      kind: kind,
      id: id,
      data: parsed.$1,
      body: parsed.$2,
    );
    validate(entity);
    return entity;
  }

  Map<String, Object?> readLoose(File file) {
    final parsed = _decode(file.readAsStringSync());
    return parsed.$1;
  }

  bool _isCanonicalFile(EntityKind kind, File file) {
    final name = p.basename(file.path);
    return switch (kind) {
      EntityKind.domain => name == 'domain.md',
      EntityKind.milestone => name == 'milestone.md',
      EntityKind.task => name == 'task.yaml' || name.startsWith('TSK-'),
      _ =>
        name.startsWith('${kind.prefix}-') &&
            (name.endsWith('.yaml') || name.endsWith('.md')),
    };
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
}
