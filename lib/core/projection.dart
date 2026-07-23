import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'canonical_repository.dart';
import 'models.dart';
import 'task_codec.dart';
import 'workspace.dart';

class ProjectionStore {
  ProjectionStore(this.workspace);

  final Workspace workspace;
  Database? _database;

  Database open() {
    workspace.ensureLayout();
    if (_database != null) return _database!;
    try {
      _database = sqlite3.open(workspace.database.path);
      _database!.select('PRAGMA schema_version');
    } on SqliteException {
      _database?.close();
      _database = null;
      if (workspace.database.existsSync()) workspace.database.deleteSync();
      _database = sqlite3.open(workspace.database.path);
    }
    return _database!..execute('''
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS tasks (
          id TEXT PRIMARY KEY,
          domain_id TEXT NOT NULL,
          milestone_id TEXT NOT NULL,
          title TEXT NOT NULL,
          status TEXT NOT NULL,
          meta_current INTEGER NOT NULL,
          target_environment TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS operations (
          operation_id TEXT PRIMARY KEY,
          task_id TEXT NOT NULL,
          reserved_run_id TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS control_requests (
          id TEXT PRIMARY KEY,
          operation_id TEXT NOT NULL,
          task_id TEXT NOT NULL,
          command TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS control_dispositions (
          request_id TEXT PRIMARY KEY,
          disposition TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS runs (
          id TEXT PRIMARY KEY,
          operation_id TEXT NOT NULL UNIQUE,
          task_id TEXT NOT NULL,
          status TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS skill_invocations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          run_id TEXT NOT NULL,
          skill_id TEXT NOT NULL,
          round INTEGER NOT NULL,
          sequence INTEGER NOT NULL,
          UNIQUE(run_id, sequence)
        );
        CREATE TABLE IF NOT EXISTS knowledge_events (
          id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL,
          entity_type TEXT NOT NULL,
          entity_ref TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS canonical_entities (
          entity_type TEXT NOT NULL,
          id TEXT NOT NULL,
          title TEXT,
          status TEXT,
          body TEXT NOT NULL,
          PRIMARY KEY(entity_type, id)
        );
        CREATE TABLE IF NOT EXISTS entity_relations (
          source_type TEXT NOT NULL,
          source_id TEXT NOT NULL,
          relation TEXT NOT NULL,
          target_id TEXT NOT NULL,
          PRIMARY KEY(source_type, source_id, relation, target_id)
        );
      ''');
  }

  List<WorkTask> rebuild() {
    final database = open();
    final files =
        workspace.tasks
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.yaml'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final tasks = files.map(TaskCodec.read).toList();
    final repository = CanonicalRepository(workspace);
    final entities = EntityKind.values
        .where((kind) => kind != EntityKind.task)
        .expand(repository.list)
        .toList();
    database.execute('BEGIN IMMEDIATE');
    try {
      database.execute('DELETE FROM tasks');
      database.execute('DELETE FROM canonical_entities');
      database.execute('DELETE FROM entity_relations');
      database.execute('DELETE FROM operations');
      database.execute('DELETE FROM control_requests');
      database.execute('DELETE FROM control_dispositions');
      database.execute('DELETE FROM runs');
      database.execute('DELETE FROM skill_invocations');
      database.execute('DELETE FROM knowledge_events');
      final insert = database.prepare(
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
          insert.execute([
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
          for (final relation in [
            ('domain_id', task.domainId),
            ('milestone_id', task.milestoneId),
          ]) {
            relationInsert.execute([
              EntityKind.task.type,
              task.id,
              relation.$1,
              relation.$2,
            ]);
          }
        }
      } finally {
        insert.close();
      }
      try {
        for (final entity in entities) {
          entityInsert.execute([
            entity.kind.type,
            entity.id,
            entity.data['title'] ?? entity.data['name'],
            entity.data['status'],
            entity.body,
          ]);
          _insertRelations(entity, relationInsert);
          _restoreSpecialized(entity, database);
        }
      } finally {
        entityInsert.close();
        relationInsert.close();
      }
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
    return tasks;
  }

  void _insertRelations(CanonicalEntity entity, PreparedStatement insert) {
    void visit(String key, Object? value) {
      if (value is Map) {
        for (final entry in value.entries) {
          visit(entry.key.toString(), entry.value);
        }
      } else if (value is List) {
        for (final item in value) {
          visit(key, item);
        }
      } else if (value is String &&
          (key.endsWith('_id') || key.endsWith('_ids'))) {
        insert.execute([entity.kind.type, entity.id, key, value]);
      }
    }

    for (final entry in entity.data.entries) {
      if (entry.key != 'id') visit(entry.key, entry.value);
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
        break;
      case EntityKind.controlDisposition:
        database.execute('INSERT INTO control_dispositions VALUES (?, ?, ?)', [
          data['request_id'],
          data['disposition'],
          data['occurred_at'],
        ]);
        break;
      case EntityKind.run:
        database.execute('INSERT INTO runs VALUES (?, ?, ?, ?)', [
          entity.id,
          data['operation_id'],
          data['task_id'],
          data['status'],
        ]);
        break;
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
        break;
      default:
        break;
    }
  }

  void dispose() {
    _database?.close();
    _database = null;
  }
}
