import 'dart:io';

import 'package:under_claw_work/core/worklog_core.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.contains('--help')) {
    stdout.writeln('''
worklog <command> [workspace]

Commands:
  setup <path> <environment-name> [remote]
             connect/init a user-selected Git workspace, or clone a remote
  init       create the portable workspace layout and local SQLite projection
  task-list  rebuild the projection and list tasks
  doctor     verify workspace and report locked capabilities
''');
    return;
  }
  if (arguments.first == 'setup') {
    if (arguments.length < 3) {
      stderr.writeln(
        'Usage: worklog setup <local-path> <environment-name> [remote]',
      );
      exitCode = 64;
      return;
    }
    final result = await SetupService().setup(
      SetupRequest(
        localPath: arguments[1],
        environmentName: arguments[2],
        privateRemote: arguments.length > 3 ? Uri.parse(arguments[3]) : null,
      ),
    );
    stdout.writeln('Workspace ready: ${result.workspace.root.path}');
    stdout.writeln('Environment: ${result.environmentId}');
    stdout.writeln('Clone: ${result.cloned ? "completed" : "not-required"}');
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
