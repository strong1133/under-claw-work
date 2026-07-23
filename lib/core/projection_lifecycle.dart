import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'canonical_repository.dart';
import 'task_repository.dart';
import 'workspace.dart';

class ProjectionResult {
  const ProjectionResult({
    required this.fingerprint,
    required this.rebuilt,
    required this.taskCount,
    required this.entityCount,
  });

  final String fingerprint;
  final bool rebuilt;
  final int taskCount;
  final int entityCount;
}

class ProjectionLifecycle {
  ProjectionLifecycle(this.workspace);

  static const formatVersion = 1;
  final Workspace workspace;

  ProjectionResult rebuildIfNeeded({bool force = false}) {
    workspace.ensureLayout();
    final fingerprint = canonicalFingerprint();
    final current = _metadata();
    if (!force &&
        current != null &&
        current.$1 == formatVersion &&
        current.$2 == fingerprint &&
        _integrityOk(workspace.database)) {
      return ProjectionResult(
        fingerprint: fingerprint,
        rebuilt: false,
        taskCount: current.$3,
        entityCount: current.$4,
      );
    }
    return _withLock(() => _rebuild(fingerprint));
  }

  void recover() {
    workspace.ensureLayout();
    _removeSidecars();
    final temporary = _temporary;
    final backup = _backup;
    if (temporary.existsSync()) temporary.deleteSync();
    if (!workspace.database.existsSync() &&
        backup.existsSync() &&
        _integrityOk(backup)) {
      backup.renameSync(workspace.database.path);
    } else if (backup.existsSync()) {
      backup.deleteSync();
    }
  }

  String canonicalFingerprint() {
    workspace.ensureLayout();
    final files =
        workspace.workdb
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where(
              (file) =>
                  !p.isWithin(workspace.local.path, file.path) &&
                  !file.path.endsWith('.tmp'),
            )
            .toList()
          ..sort((left, right) => left.path.compareTo(right.path));
    final fingerprintBytes = BytesBuilder(copy: false);
    for (final file in files) {
      fingerprintBytes.add(
        utf8.encode('${p.relative(file.path, from: workspace.root.path)}\n'),
      );
      fingerprintBytes.add(file.readAsBytesSync());
    }
    return sha256.convert(fingerprintBytes.takeBytes()).toString();
  }

  ProjectionResult _rebuild(String fingerprint) {
    recover();
    final tasks = TaskRepository(workspace).list();
    final repository = CanonicalRepository(workspace);
    final entities = EntityKind.values
        .where((kind) => kind != EntityKind.task)
        .expand(repository.list)
        .toList();
    final database = sqlite3.open(_temporary.path);
    try {
      database.execute('''
        PRAGMA journal_mode = DELETE;
        PRAGMA synchronous = FULL;
        CREATE TABLE projection_metadata (
          singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
          format_version INTEGER NOT NULL,
          canonical_fingerprint TEXT NOT NULL,
          task_count INTEGER NOT NULL,
          entity_count INTEGER NOT NULL,
          built_at TEXT NOT NULL
        );
        CREATE TABLE tasks (
          id TEXT PRIMARY KEY,
          domain_id TEXT NOT NULL,
          milestone_id TEXT NOT NULL,
          title TEXT NOT NULL,
          status TEXT NOT NULL,
          meta_current INTEGER NOT NULL,
          target_environment TEXT NOT NULL
        );
        CREATE TABLE canonical_entities (
          entity_type TEXT NOT NULL,
          id TEXT NOT NULL,
          title TEXT,
          status TEXT,
          body TEXT NOT NULL,
          PRIMARY KEY(entity_type, id)
        );
        CREATE TABLE entity_relations (
          source_type TEXT NOT NULL,
          source_id TEXT NOT NULL,
          relation TEXT NOT NULL,
          target_id TEXT NOT NULL,
          PRIMARY KEY(source_type, source_id, relation, target_id)
        );
        CREATE TABLE operations (
          operation_id TEXT PRIMARY KEY,
          task_id TEXT NOT NULL,
          reserved_run_id TEXT NOT NULL UNIQUE
        );
        CREATE TABLE control_requests (
          id TEXT PRIMARY KEY,
          operation_id TEXT NOT NULL,
          task_id TEXT NOT NULL,
          command TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        CREATE TABLE control_dispositions (
          request_id TEXT PRIMARY KEY,
          disposition TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        CREATE TABLE runs (
          id TEXT PRIMARY KEY,
          operation_id TEXT NOT NULL UNIQUE,
          task_id TEXT NOT NULL,
          status TEXT NOT NULL
        );
        CREATE TABLE skill_invocations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          run_id TEXT NOT NULL,
          skill_id TEXT NOT NULL,
          round INTEGER NOT NULL,
          sequence INTEGER NOT NULL,
          UNIQUE(run_id, sequence)
        );
        CREATE TABLE knowledge_events (
          id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL,
          entity_type TEXT NOT NULL,
          entity_ref TEXT NOT NULL
        );
      ''');
      final taskInsert = database.prepare(
        'INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?)',
      );
      final entityInsert = database.prepare(
        'INSERT INTO canonical_entities VALUES (?, ?, ?, ?, ?)',
      );
      final relationInsert = database.prepare(
        'INSERT OR IGNORE INTO entity_relations VALUES (?, ?, ?, ?)',
      );
      try {
        for (final task in tasks) {
          taskInsert.execute([
            task.id,
            task.domainId,
            task.milestoneId,
            task.title,
            task.status.name,
            task.isMetaCurrent ? 1 : 0,
            task.targetEnvironment,
          ]);
          entityInsert.execute([
            EntityKind.task.type,
            task.id,
            task.title,
            task.status.name,
            '',
          ]);
          relationInsert.execute([
            EntityKind.task.type,
            task.id,
            'domain_id',
            task.domainId,
          ]);
          relationInsert.execute([
            EntityKind.task.type,
            task.id,
            'milestone_id',
            task.milestoneId,
          ]);
          for (final objective in task.alignedObjectiveIds) {
            relationInsert.execute([
              EntityKind.task.type,
              task.id,
              'objective_ids',
              objective,
            ]);
          }
        }
        for (final entity in entities) {
          entityInsert.execute([
            entity.kind.type,
            entity.id,
            entity.data['title'] ?? entity.data['name'],
            entity.data['status'],
            entity.body,
          ]);
          _relations(entity.data).forEach(
            (relation) => relationInsert.execute([
              entity.kind.type,
              entity.id,
              relation.$1,
              relation.$2,
            ]),
          );
          _restoreSpecialized(entity, database);
        }
      } finally {
        taskInsert.close();
        entityInsert.close();
        relationInsert.close();
      }
      database.execute(
        'INSERT INTO projection_metadata VALUES (1, ?, ?, ?, ?, ?)',
        [
          formatVersion,
          fingerprint,
          tasks.length,
          entities.length,
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      final result = database
          .select('PRAGMA integrity_check')
          .first
          .values
          .first;
      if (result != 'ok') {
        throw StateError('Projection integrity check failed.');
      }
    } finally {
      database.close();
    }
    _atomicReplace();
    return ProjectionResult(
      fingerprint: fingerprint,
      rebuilt: true,
      taskCount: tasks.length,
      entityCount: entities.length,
    );
  }

  T _withLock<T>(T Function() action) {
    final lock = _lock;
    try {
      lock.createSync(exclusive: true);
      lock.writeAsStringSync(
        '{"pid":$pid,"created_at":"${DateTime.now().toUtc().toIso8601String()}"}',
        flush: true,
      );
    } on FileSystemException {
      throw StateError('Projection rebuild is already locked.');
    }
    try {
      return action();
    } finally {
      if (lock.existsSync()) lock.deleteSync();
    }
  }

  void _atomicReplace() {
    final database = workspace.database;
    final backup = _backup;
    _removeSidecars();
    if (backup.existsSync()) backup.deleteSync();
    if (database.existsSync()) database.renameSync(backup.path);
    try {
      _temporary.renameSync(database.path);
      if (!_integrityOk(database)) {
        throw StateError('Installed projection failed integrity check.');
      }
      if (backup.existsSync()) backup.deleteSync();
      _removeSidecars();
    } catch (_) {
      if (database.existsSync()) database.deleteSync();
      if (backup.existsSync()) backup.renameSync(database.path);
      rethrow;
    }
  }

  (int, String, int, int)? _metadata() {
    if (!workspace.database.existsSync() || !_integrityOk(workspace.database)) {
      return null;
    }
    final database = sqlite3.open(
      workspace.database.path,
      mode: OpenMode.readOnly,
    );
    try {
      final tables = database.select(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='projection_metadata'",
      );
      if (tables.isEmpty) return null;
      final row = database.select('SELECT * FROM projection_metadata').first;
      return (
        row['format_version'] as int,
        row['canonical_fingerprint'] as String,
        row['task_count'] as int,
        row['entity_count'] as int,
      );
    } finally {
      database.close();
    }
  }

  bool _integrityOk(File file) {
    if (!file.existsSync()) return false;
    Database? database;
    try {
      database = sqlite3.open(file.path, mode: OpenMode.readOnly);
      return database.select('PRAGMA integrity_check').first.values.first ==
          'ok';
    } on SqliteException {
      return false;
    } finally {
      database?.close();
    }
  }

  Iterable<(String, String)> _relations(Map<String, Object?> data) sync* {
    Iterable<(String, String)> visit(String key, Object? value) sync* {
      if (value is Map) {
        for (final entry in value.entries) {
          yield* visit(entry.key.toString(), entry.value);
        }
      } else if (value is List) {
        for (final item in value) {
          yield* visit(key, item);
        }
      } else if (value is String &&
          (key.endsWith('_id') || key.endsWith('_ids'))) {
        yield (key, value);
      }
    }

    for (final entry in data.entries) {
      if (entry.key != 'id') yield* visit(entry.key, entry.value);
    }
  }

  void _restoreSpecialized(CanonicalEntity entity, Database database) {
    final data = entity.data;
    switch (entity.kind) {
      case EntityKind.controlRequest:
        database
            .execute('INSERT INTO control_requests VALUES (?, ?, ?, ?, ?)', [
              entity.id,
              data['operation_id'],
              data['task_id'],
              data['command'],
              data['requested_at'],
            ]);
        final reservedRunId = data['reserved_run_id'];
        if (data['command'] == 'start' && reservedRunId is String) {
          database.execute(
            'INSERT OR IGNORE INTO operations VALUES (?, ?, ?)',
            [data['operation_id'], data['task_id'], reservedRunId],
          );
        }
      case EntityKind.controlDisposition:
        database.execute('INSERT INTO control_dispositions VALUES (?, ?, ?)', [
          data['request_id'],
          data['disposition'],
          data['occurred_at'],
        ]);
      case EntityKind.run:
        database.execute('INSERT INTO runs VALUES (?, ?, ?, ?)', [
          entity.id,
          data['operation_id'],
          data['task_id'],
          data['status'],
        ]);
      case EntityKind.invocation:
        database.execute(
          'INSERT INTO skill_invocations '
          '(run_id, skill_id, round, sequence) VALUES (?, ?, ?, ?)',
          [
            data['run_id'],
            data['skill_id'],
            data['round'] ?? 0,
            data['sequence'],
          ],
        );
      default:
        break;
    }
  }

  File get _temporary => File('${workspace.database.path}.building');
  File get _backup => File('${workspace.database.path}.previous');
  File get _lock => File('${workspace.database.path}.lock');

  void _removeSidecars() {
    for (final suffix in const ['-wal', '-shm']) {
      final sidecar = File('${workspace.database.path}$suffix');
      if (sidecar.existsSync()) sidecar.deleteSync();
    }
  }
}
