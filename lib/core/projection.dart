import 'package:sqlite3/sqlite3.dart';

import 'models.dart';
import 'projection_lifecycle.dart';
import 'task_repository.dart';
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
          domain_id TEXT,
          milestone_id TEXT,
          title TEXT NOT NULL,
          status TEXT NOT NULL,
          meta_current INTEGER NOT NULL,
          target_environment TEXT NOT NULL,
          processing_mode TEXT NOT NULL,
          project_ids_json TEXT NOT NULL,
          target_environment_ids_json TEXT NOT NULL,
          model_selection_keys_json TEXT NOT NULL,
          parent_task_id TEXT,
          related_task_ids_json TEXT NOT NULL
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
    dispose();
    ProjectionLifecycle(workspace).rebuildIfNeeded(force: true);
    open();
    return TaskRepository(workspace).list();
  }

  List<Map<String, Object?>> searchKnowledge(String query) {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];
    return open()
        .select(
          '''
          SELECT id, title, body
          FROM canonical_entities
          WHERE entity_type = 'knowledge'
            AND (lower(COALESCE(title, '')) LIKE lower(?)
              OR lower(body) LIKE lower(?))
          ORDER BY id
          ''',
          ['%$normalized%', '%$normalized%'],
        )
        .map(
          (row) => <String, Object?>{
            'id': row['id'],
            'title': row['title'],
            'body': row['body'],
          },
        )
        .toList();
  }

  void dispose() {
    _database?.close();
    _database = null;
  }
}
