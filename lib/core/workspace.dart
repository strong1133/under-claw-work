import 'dart:io';

import 'package:path/path.dart' as p;

class Workspace {
  Workspace(this.root);

  final Directory root;

  Directory get workdb => Directory(p.join(root.path, 'workdb'));
  Directory get tasks => Directory(p.join(workdb.path, 'tasks'));
  Directory get controls => Directory(p.join(workdb.path, 'controls'));
  Directory get runs => Directory(p.join(workdb.path, 'runs'));
  Directory get local => Directory(p.join(root.path, '.worklog'));
  File get database => File(p.join(local.path, 'projection.sqlite3'));

  void ensureLayout() {
    for (final directory in [workdb, tasks, controls, runs, local]) {
      directory.createSync(recursive: true);
    }
  }
}
