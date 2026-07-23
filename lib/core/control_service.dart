import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'id.dart';
import 'models.dart';
import 'projection.dart';
import 'workspace.dart';

class ControlService {
  ControlService(this.workspace, this.projection);

  final Workspace workspace;
  final ProjectionStore projection;

  String requestStart(WorkTask task, String operationId) {
    if (!task.isMetaCurrent) {
      throw StateError('Task Meta Prompt is missing, stale, or unapproved.');
    }
    final database = projection.open();
    final existing = database.select(
      'SELECT reserved_run_id FROM operations WHERE operation_id = ?',
      [operationId],
    );
    if (existing.isNotEmpty) {
      return existing.single['reserved_run_id'] as String;
    }

    final runId = newId('RUN');
    final requestId = newId('CTL');
    database.execute('BEGIN IMMEDIATE');
    try {
      database.execute('INSERT INTO operations VALUES (?, ?, ?)', [
        operationId,
        task.id,
        runId,
      ]);
      database.execute('INSERT INTO control_requests VALUES (?, ?, ?, ?, ?)', [
        requestId,
        operationId,
        task.id,
        ControlCommand.start.name,
        DateTime.now().toUtc().toIso8601String(),
      ]);
      database.execute('INSERT INTO runs VALUES (?, ?, ?, ?)', [
        runId,
        operationId,
        task.id,
        'requested',
      ]);
      database.execute('COMMIT');
    } on SqliteException {
      database.execute('ROLLBACK');
      final recovered = database.select(
        'SELECT reserved_run_id FROM operations WHERE operation_id = ?',
        [operationId],
      );
      if (recovered.isNotEmpty) {
        return recovered.single['reserved_run_id'] as String;
      }
      rethrow;
    }
    _writeExclusive(
      File(p.join(workspace.controls.path, '$requestId.yaml')),
      '''
schema_version: 1
id: $requestId
operation_id: $operationId
task_id: ${task.id}
command: start
reserved_run_id: $runId
''',
    );
    return runId;
  }

  void addDisposition(String requestId, String disposition) {
    final database = projection.open();
    database.execute('INSERT INTO control_dispositions VALUES (?, ?, ?)', [
      requestId,
      disposition,
      DateTime.now().toUtc().toIso8601String(),
    ]);
    _writeExclusive(
      File(p.join(workspace.controls.path, '$requestId.disposition.yaml')),
      'request_id: $requestId\ndisposition: $disposition\n',
    );
  }

  void _writeExclusive(File file, String content) {
    file.createSync(exclusive: true);
    file.writeAsStringSync(content, flush: true);
  }
}
