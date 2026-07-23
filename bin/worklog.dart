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
  entity-create <workspace> <kind> <title> [domain-id] [milestone-id]
  entity-update <workspace> <kind> <id> <title>
  entity-archive <workspace> <kind> <id>
  entity-link <workspace> <kind> <id> <field> <target-kind> <target-id>
  graph-validate <workspace>
  knowledge-search <workspace> <query>
  context-build <workspace> <task-id> [token-budget]
  task-create <workspace> <domain-id> <milestone-id> <title> <environment-id>
  task-policy <workspace> <task-id> <derive:true|false> <followup:true|false> <depth>
  task-candidate-propose <workspace> <parent-task-id> <title> <draft-file>
             <objective-ids-csv> <knowledge-ids-csv> <reference-ids-csv> <reason>
  task-candidate-dispose <workspace> <candidate-id> <accept|reject>
  task-candidate-list <workspace>
  task-prompt <workspace> <task-id> <draft|meta|approve> [content-file]
  task-control <workspace> <task-id> <command> [run-id]
             request start|pause|resume|cancel|complete
  worker-next <workspace> <environment-id> <executable> [runner-arguments...]
             execute the oldest pending start request using a JSON runner
  worker-recover <workspace> <environment-id>
             mark expired worker runs interrupted and release stale claims
  control-disposition <workspace> <request-id> <accepted|rejected|withdrawn|expired|superseded>
  invocation-record <workspace> <run-id> <skill-id> <round> <sequence> <status>
  review-record <workspace> <run-id> <score> <independent:true|false>
  git-status <workspace>
  git-pull <workspace>
  projection-rebuild <workspace> [--force]
  migrate-dry-run <workspace> <legacy-path>
  migrate-import <workspace> <legacy-path> <domain-id> <milestone-id>
             <environment-id> --approve
  migrate-rollback <workspace> <import-id>
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
      case 'entity-create':
        if (arguments.length < 4) {
          throw const FormatException(
            'entity-create requires workspace, kind and title.',
          );
        }
        final kind = EntityKind.values.byName(arguments[2]);
        final entity = EntityService(workspace).create(
          kind: kind,
          title: arguments[3],
          domainId: arguments.length > 4 ? arguments[4] : null,
          milestoneId: arguments.length > 5 ? arguments[5] : null,
        );
        projection.rebuild();
        stdout.writeln(entity.id);
      case 'entity-update':
        if (arguments.length < 5) {
          throw const FormatException(
            'entity-update requires workspace, kind, id and title.',
          );
        }
        final kind = EntityKind.values.byName(arguments[2]);
        final service = EntityService(workspace);
        final current = service.repository.get(kind, arguments[3]);
        if (current == null) throw StateError('Entity not found.');
        final entity = service.update(current, title: arguments[4]);
        projection.rebuild();
        stdout.writeln(entity.id);
      case 'entity-archive':
        if (arguments.length < 4) {
          throw const FormatException(
            'entity-archive requires workspace, kind and id.',
          );
        }
        final kind = EntityKind.values.byName(arguments[2]);
        final service = EntityService(workspace);
        final current = service.repository.get(kind, arguments[3]);
        if (current == null) throw StateError('Entity not found.');
        service.archive(current);
        projection.rebuild();
        stdout.writeln('${current.id}\tarchived');
      case 'entity-link':
        if (arguments.length < 7) {
          throw const FormatException(
            'entity-link requires workspace, kind, id, field, target kind '
            'and target id.',
          );
        }
        final kind = EntityKind.values.byName(arguments[2]);
        final service = EntityService(workspace);
        final current = service.repository.get(kind, arguments[3]);
        if (current == null) throw StateError('Entity not found.');
        service.link(
          current,
          field: arguments[4],
          targetKind: EntityKind.values.byName(arguments[5]),
          targetId: arguments[6],
        );
        projection.rebuild();
        stdout.writeln('${current.id}\tlinked');
      case 'graph-validate':
        EntityService(workspace).validateGraph();
        WorklogContractValidator().validateRepository(
          CanonicalRepository(workspace),
          TaskRepository(workspace).list(),
        );
        stdout.writeln('graph=valid');
      case 'knowledge-search':
        if (arguments.length < 3) {
          throw const FormatException(
            'knowledge-search requires workspace and query.',
          );
        }
        projection.rebuild();
        for (final result in projection.searchKnowledge(arguments[2])) {
          stdout.writeln('${result['id']}\t${result['title'] ?? ''}');
        }
      case 'context-build':
        if (arguments.length < 3) {
          throw const FormatException(
            'context-build requires workspace and task id.',
          );
        }
        final context = EntityService(workspace).buildContext(arguments[2]);
        stdout.writeln('task=${context.taskId}');
        stdout.writeln('domain=${context.domain?.id ?? ""}');
        stdout.writeln('milestone=${context.milestone?.id ?? ""}');
        stdout.writeln(
          'objectives=${context.objectives.map((item) => item.id).join(",")}',
        );
        stdout.writeln(
          'knowledge=${context.knowledge.map((item) => item.id).join(",")}',
        );
        stdout.writeln(
          'references=${context.references.map((item) => item.id).join(",")}',
        );
        final execution = EntityService(workspace).buildExecutionContext(
          arguments[2],
          tokenBudget: arguments.length > 3 ? int.parse(arguments[3]) : 4096,
        );
        stdout.writeln(
          'budget=${execution.tokenBudget} '
          'estimated_tokens=${execution.estimatedTokens}',
        );
        for (final entry in execution.entries) {
          stdout.writeln(
            'context=${entry.id}\tprovenance=${entry.provenance}\t'
            'distance=${entry.relationDistance}\t'
            'contradictions=${entry.contradictionIds.join(",")}',
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
          operationId: newId('OPR'),
          runId: arguments.length > 4 ? arguments[4] : null,
        );
        stdout.writeln('request=${command.name} run=$run');
      case 'worker-next':
        if (arguments.length < 4) {
          throw const FormatException(
            'worker-next requires workspace, environment and executable.',
          );
        }
        final result = await TaskExecutionWorker(
          workspace: workspace,
          projection: projection,
          environmentId: arguments[2],
          remoteClaims: GitRemoteClaimService(workspace),
          runner: ProcessRunnerAdapter(
            executable: arguments[3],
            arguments: arguments.skip(4).toList(),
            workingDirectory: workspace.root.path,
          ),
        ).runNext();
        if (result == null) {
          stdout.writeln('worker=idle');
        } else {
          stdout.writeln(
            'run=${result.runId}\tstatus=${result.status}'
            '${result.error == null ? "" : "\terror=${result.error}"}',
          );
        }
      case 'worker-recover':
        if (arguments.length < 3) {
          throw const FormatException(
            'worker-recover requires workspace and environment.',
          );
        }
        final recovered = TaskExecutionWorker(
          workspace: workspace,
          projection: projection,
          environmentId: arguments[2],
          runner: ProcessRunnerAdapter(
            executable: Platform.resolvedExecutable,
            arguments: const [],
          ),
        ).recoverExpiredRuns();
        stdout.writeln('recovered=${recovered.join(",")}');
      case 'task-policy':
        if (arguments.length < 6) {
          throw const FormatException(
            'task-policy requires workspace, task id, derive, followup and '
            'depth.',
          );
        }
        final repository = TaskRepository(workspace);
        final task = repository.get(arguments[2]);
        if (task == null) throw StateError('Task not found: ${arguments[2]}');
        final updated = repository.update(
          task.copyWith(
            autoDeriveTasks: bool.parse(arguments[3]),
            autoFollowupTasks: bool.parse(arguments[4]),
            maxGenerationDepth: int.parse(arguments[5]),
          ),
        );
        projection.rebuild();
        stdout.writeln(
          'task=${updated.id} derive=${updated.autoDeriveTasks} '
          'followup=${updated.autoFollowupTasks} '
          'depth=${updated.maxGenerationDepth}',
        );
      case 'task-candidate-propose':
        if (arguments.length < 9) {
          throw const FormatException(
            'task-candidate-propose requires workspace, parent, title, Draft '
            'file, Objective IDs, Knowledge IDs, Reference IDs and reason.',
          );
        }
        List<String> csv(String value) => value
            .split(',')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList();
        final candidate = TaskCandidateService(workspace).propose(
          parentTaskId: arguments[2],
          title: arguments[3],
          draft: File(arguments[4]).readAsStringSync(),
          objectiveIds: csv(arguments[5]),
          knowledgeIds: csv(arguments[6]),
          referenceIds: csv(arguments[7]),
          reason: arguments[8],
        );
        stdout.writeln('${candidate.id}\tpending');
      case 'task-candidate-dispose':
        if (arguments.length < 4) {
          throw const FormatException(
            'task-candidate-dispose requires workspace, candidate and action.',
          );
        }
        final candidates = TaskCandidateService(workspace);
        if (arguments[3] == 'accept') {
          final task = candidates.accept(arguments[2]);
          stdout.writeln('${arguments[2]}\taccepted\ttask=${task.id}');
        } else if (arguments[3] == 'reject') {
          candidates.reject(arguments[2]);
          stdout.writeln('${arguments[2]}\trejected');
        } else {
          throw FormatException('Unknown candidate action: ${arguments[3]}');
        }
      case 'task-candidate-list':
        for (final candidate in TaskCandidateService(workspace).list()) {
          stdout.writeln(
            '${candidate.id}\t${candidate.disposition.name}\t'
            '${candidate.title}\tparent=${candidate.parentTaskId}',
          );
        }
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
      case 'projection-rebuild':
        final result = ProjectionLifecycle(
          workspace,
        ).rebuildIfNeeded(force: arguments.contains('--force'));
        stdout.writeln(
          'rebuilt=${result.rebuilt} fingerprint=${result.fingerprint} '
          'tasks=${result.taskCount} entities=${result.entityCount}',
        );
      case 'migrate-dry-run':
        if (arguments.length < 3) {
          throw const FormatException(
            'migrate-dry-run requires workspace and legacy path.',
          );
        }
        final result = LegacyMigrationService(
          workspace,
        ).dryRun(Directory(arguments[2]));
        stdout.writeln(
          'dry_run=true import=${result.importId} '
          'blocks=${result.blocks.length} skipped=${result.skipped.length} '
          'canonical_writes=0',
        );
      case 'migrate-import':
        if (arguments.length < 7 || !arguments.contains('--approve')) {
          throw const FormatException(
            'migrate-import requires workspace, legacy path, domain, '
            'milestone, environment and --approve.',
          );
        }
        final service = LegacyMigrationService(workspace);
        final plan = service.dryRun(Directory(arguments[2]));
        final tasks = service.import(
          plan,
          approved: true,
          domainId: arguments[3],
          milestoneId: arguments[4],
          targetEnvironment: arguments[5],
        );
        projection.rebuild();
        stdout.writeln(
          'import=${plan.importId} imported=${tasks.length} '
          'source_fingerprint=${plan.sourceFingerprint}',
        );
      case 'migrate-rollback':
        if (arguments.length < 3) {
          throw const FormatException(
            'migrate-rollback requires workspace and import id.',
          );
        }
        LegacyMigrationService(workspace).rollback(arguments[2]);
        projection.rebuild();
        stdout.writeln('rollback=${arguments[2]}');
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
