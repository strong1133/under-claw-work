import 'dart:io';

import 'package:path/path.dart' as p;

class Workspace {
  Workspace(this.root);

  final Directory root;

  Directory get workdb => Directory(p.join(root.path, 'workdb'));
  Directory get tasks => Directory(p.join(workdb.path, 'tasks'));
  Directory get domains => Directory(p.join(workdb.path, 'domains'));
  Directory get milestones => Directory(p.join(workdb.path, 'milestones'));
  Directory get objectives => Directory(p.join(workdb.path, 'objectives'));
  Directory get knowledge => Directory(p.join(workdb.path, 'knowledge'));
  Directory get references => Directory(p.join(workdb.path, 'references'));
  Directory get events => Directory(p.join(workdb.path, 'events'));
  Directory get claims => Directory(p.join(workdb.path, 'claims'));
  Directory get controls => Directory(p.join(workdb.path, 'control-requests'));
  Directory get controlDispositions =>
      Directory(p.join(workdb.path, 'control-dispositions'));
  Directory get runs => Directory(p.join(workdb.path, 'runs'));
  Directory get invocations => Directory(p.join(workdb.path, 'invocations'));
  Directory get config => Directory(p.join(workdb.path, 'config'));
  Directory get candidates => Directory(p.join(workdb.path, 'task-candidates'));
  Directory get migrations => Directory(p.join(local.path, 'migrations'));
  Directory get local => Directory(p.join(root.path, '.worklog'));
  File get database => File(p.join(local.path, 'projection.sqlite3'));
  File taskRelations(String taskId) =>
      File(p.join(tasks.path, taskId, 'relations.yaml'));

  void ensureLayout() {
    for (final directory in [
      workdb,
      tasks,
      domains,
      milestones,
      objectives,
      knowledge,
      references,
      events,
      claims,
      controls,
      controlDispositions,
      runs,
      invocations,
      config,
      candidates,
      local,
      migrations,
    ]) {
      directory.createSync(recursive: true);
    }
  }
}
