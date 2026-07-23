import 'dart:io';

import 'package:under_claw_work/core/worklog_core.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.contains('--help')) {
    stdout.writeln('''
worklog <command> [workspace]

Commands:
  initialize <path> <environment-name> [remote]
             initialize a workspace and report connected Agent hosts
  setup <path> <environment-name> [remote]
             connect/init a user-selected Git workspace, or clone a remote
  host-list  detect Hermes, Claude Code and Codex connections
  init       create the portable workspace layout and local SQLite projection
  task-list  rebuild the projection and list tasks
  entity-list <workspace> [kind]
             list canonical Domain/Milestone/Objective/Knowledge/Reference data
  task-create <workspace> <domain-id> <milestone-id> <title> <environment-id>
  task-prompt <workspace> <task-id> <draft|meta|approve> [content-file]
  task-control <workspace> <task-id> <command> [run-id]
             request start|pause|resume|cancel|complete
  control-disposition <workspace> <request-id> <accepted|rejected>
  invocation-record <workspace> <run-id> <skill-id> <round> <sequence> <status>
  review-record <workspace> <run-id> <score> <independent:true|false>
  git-status <workspace>
  git-pull <workspace>
  migrate-dry-run <legacy-path>
  doctor     verify workspace and report locked capabilities
''');
    return;
  }
  if (arguments.first == 'setup' || arguments.first == 'initialize') {
    if (arguments.length < 3) {
      stderr.writeln(
        'Usage: worklog ${arguments.first} '
        '<local-path> <environment-name> [remote]',
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
    if (arguments.first == 'initialize') _printHosts();
    return;
  }
  if (arguments.first == 'host-list') {
    _printHosts();
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
      case 'entity-list':
        final kind = arguments.length > 2
            ? EntityKind.values.byName(arguments[2])
            : null;
        for (final entity in CanonicalRepository(workspace).list(kind)) {
          stdout.writeln(
            '${entity.kind.type}\t${entity.id}\t'
            '${entity.data['title'] ?? entity.data['name'] ?? ''}',
          );
        }
      case 'task-create':
        if (arguments.length < 6) {
          throw const FormatException(
            'task-create requires workspace, domain, milestone, title and '
            'environment.',
          );
        }
        final task = TaskRepository(workspace).create(
          WorkTask(
            id: newId('TSK'),
            domainId: arguments[2],
            milestoneId: arguments[3],
            title: arguments[4],
            status: TaskStatus.draft,
            promptDraft: '',
            promptMeta: '',
            promptDraftRevision: 1,
            promptMetaSourceRevision: 0,
            approval: PromptApproval.missing,
            autoDeriveTasks: false,
            targetEnvironment: arguments[5],
          ),
        );
        projection.rebuild();
        stdout.writeln(task.id);
      case 'task-control':
        if (arguments.length < 4) {
          throw const FormatException(
            'task-control requires workspace, task id and command.',
          );
        }
        final task = TaskRepository(workspace).get(arguments[2]);
        if (task == null) throw StateError('Task not found: ${arguments[2]}');
        final command = ControlCommand.values.byName(arguments[3]);
        final run = ControlService(workspace, projection).request(
          task,
          command,
          operationId: newId('OP'),
          runId: arguments.length > 4 ? arguments[4] : null,
        );
        stdout.writeln('request=${command.name} run=$run');
      case 'task-prompt':
        if (arguments.length < 4) {
          throw const FormatException(
            'task-prompt requires workspace, task id and action.',
          );
        }
        final repository = TaskRepository(workspace);
        final task = repository.get(arguments[2]);
        if (task == null) throw StateError('Task not found: ${arguments[2]}');
        final action = arguments[3];
        if (action != 'approve' && arguments.length < 5) {
          throw const FormatException('draft/meta requires a content file.');
        }
        final updated = switch (action) {
          'approve' => repository.approveMeta(task),
          'draft' => repository.saveDraft(
            task,
            File(arguments[4]).readAsStringSync(),
          ),
          'meta' => repository.saveMeta(
            task,
            File(arguments[4]).readAsStringSync(),
          ),
          _ => throw FormatException('Unknown prompt action: $action'),
        };
        projection.rebuild();
        stdout.writeln('task=${updated.id} approval=${updated.approval.name}');
      case 'control-disposition':
        if (arguments.length < 4) {
          throw const FormatException(
            'control-disposition requires workspace, request and disposition.',
          );
        }
        ControlService(
          workspace,
          projection,
        ).addDisposition(arguments[2], arguments[3]);
        stdout.writeln('disposition=${arguments[3]} request=${arguments[2]}');
      case 'invocation-record':
        if (arguments.length < 7) {
          throw const FormatException(
            'invocation-record requires workspace, run, skill, round, '
            'sequence and status.',
          );
        }
        final invocationId = newId('SKI');
        final now = DateTime.now().toUtc().toIso8601String();
        CanonicalRepository(workspace).create(
          CanonicalEntity(
            kind: EntityKind.invocation,
            id: invocationId,
            data: {
              'schema_version': 1,
              'id': invocationId,
              'type': 'skill_invocation',
              'run_id': arguments[2],
              'skill_id': arguments[3],
              'round': int.parse(arguments[4]),
              'sequence': int.parse(arguments[5]),
              'status': arguments[6],
              'bundle_version': 'mvp-1',
              'started_at': now,
              'finished_at': now,
            },
          ),
        );
        projection.rebuild();
        stdout.writeln(invocationId);
      case 'review-record':
        if (arguments.length < 5) {
          throw const FormatException(
            'review-record requires workspace, run, score and independent.',
          );
        }
        final eventId = newId('EVT');
        CanonicalRepository(workspace).create(
          CanonicalEntity(
            kind: EntityKind.event,
            id: eventId,
            data: {
              'schema_version': 1,
              'id': eventId,
              'type': 'event',
              'event_type': 'reviewer_verdict',
              'run_id': arguments[2],
              'score': double.parse(arguments[3]),
              'independent_reviewer': bool.parse(arguments[4]),
              'occurred_at': DateTime.now().toUtc().toIso8601String(),
            },
          ),
        );
        projection.rebuild();
        stdout.writeln(eventId);
      case 'git-status':
        final status = await GitSyncService(workspace).status();
        stdout.writeln('state=${status.state.name} head=${status.head}');
      case 'git-pull':
        await GitSyncService(workspace).pullFastForward();
        projection.rebuild();
        stdout.writeln('pull=ok');
      case 'migrate-dry-run':
        final source = Directory(arguments[1]);
        if (!source.existsSync()) throw StateError('Legacy path not found.');
        final markdown = source
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.md'))
            .length;
        stdout.writeln('dry_run=true markdown_files=$markdown writes=0');
      case 'doctor':
        workspace.ensureLayout();
        projection.open();
        stdout.writeln('workspace=ok');
        stdout.writeln('sqlite=ok');
        stdout.writeln('auth_provider=pending_selection');
        stdout.writeln('hermes_contract=current_upstream_documented');
        stdout.writeln('hermes_live_e2e=not_run');
      default:
        stderr.writeln('Unknown command: ${arguments.first}');
        exitCode = 64;
    }
  } finally {
    projection.dispose();
  }
}

void _printHosts() {
  final hosts = HostDiscoveryService().discover();
  for (final host in hosts) {
    final state = host.connected
        ? 'connected'
        : host.detected
        ? 'detected'
        : 'not-found';
    stdout.writeln('${host.id}\t$state\t${host.home.path}');
  }
  if (!hosts.any((host) => host.detected)) {
    stdout.writeln(
      'No Agent host detected; Flutter and CLI management remain available.',
    );
  }
}
