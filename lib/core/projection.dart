import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';
import 'task_codec.dart';
import 'workspace.dart';

class ProjectionStore {
  ProjectionStore(this.workspace);

  final Workspace workspace;
  Database? _database;

  Database open() {
    workspace.ensureLayout();
    return _database ??= sqlite3.open(workspace.database.path)
      ..execute('''
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
      ''');
  }

  List<WorkTask> rebuild() {
    final database = open();
    final files =
        workspace.tasks
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.yaml'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final tasks = files.map(TaskCodec.read).toList();
    database.execute('BEGIN IMMEDIATE');
    try {
      database.execute('DELETE FROM tasks');
      final insert = database.prepare(
        'INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?)',
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
        }
      } finally {
        insert.close();
      }
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
    return tasks;
  }

  void dispose() => _database?.close();
}
