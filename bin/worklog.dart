import 'dart:io';

import 'package:under_claw_work/core/worklog_core.dart';

void main(List<String> arguments) {
  if (arguments.isEmpty || arguments.contains('--help')) {
    stdout.writeln('''
worklog <command> [workspace]

Commands:
  init       create the portable workspace layout and local SQLite projection
  task-list  rebuild the projection and list tasks
  doctor     verify workspace and report locked capabilities
''');
    return;
  }
  final workspace = Workspace(
    Directory(arguments.length > 1 ? arguments[1] : Directory.current.path),
  );
  final projection = ProjectionStore(workspace);
  try {
    switch (arguments.first) {
      case 'init':
        workspace.ensureLayout();
        projection.rebuild();
        stdout.writeln('Workspace ready: ${workspace.root.path}');
      case 'task-list':
        for (final task in projection.rebuild()) {
          stdout.writeln(
            '${task.id}\t${task.status.name}\t${task.title}\t'
            'meta=${task.isMetaCurrent ? "ready" : "locked"}',
          );
        }
      case 'doctor':
        workspace.ensureLayout();
        projection.open();
        stdout.writeln('workspace=ok');
        stdout.writeln('sqlite=ok');
        stdout.writeln('auth_provider=pending_selection');
        stdout.writeln('hermes_adapter=not_validated');
      default:
        stderr.writeln('Unknown command: ${arguments.first}');
        exitCode = 64;
    }
  } finally {
    projection.dispose();
  }
}
