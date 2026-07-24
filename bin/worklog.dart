import 'dart:convert';
import 'dart:io';

import 'package:under_claw_work/core/worklog_cli_core.dart';

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
  env-register <workspace> <alias> [kind] [capabilities-csv]
             register this host as an environment (idempotent by machine key)
  env-list <workspace>
             list registered environments (id, alias, os, kind, status)
  env-rename <workspace> <env-id> <alias>
             edit the display alias without changing the immutable id
  env-set-kind <workspace> <env-id> <desktop|server|headless|agent_runtime>
  env-set-capabilities <workspace> <env-id> <capabilities-csv>
  env-deactivate <workspace> <env-id>
  env-activate <workspace> <env-id>
  env-relink <workspace> <env-id>
             re-bind an env id to this host after a salt/reinstall loss
  agent-register <workspace> <name> <kind> <env-id>
             register an Agent bound to an Environment by ENV id
  agent-rename <workspace> <agent-id> <name>
             edit the display name without changing the immutable id
  agent-set-kind <workspace> <agent-id> <kind>
             edit the runtime kind label (e.g. hermes, claude, codex)
  agent-list <workspace>
  match-propose <workspace> <subject-id> <target-id> <actor-type> <actor-id>
             [mode] [confidence] [evidence]
             link a Knowledge/Reference to a Domain/Milestone/Objective/Task
  match-approve|match-reject|match-revoke <workspace> <match-id>
             <actor-type> <actor-id> [reason]
  match-list <workspace>
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
  memory-recall <workspace> <domain|milestone|task> <scope-id>
             cross-agent unified recall (restricted material excluded on CLI)
  task-create <workspace> <domain-id> <milestone-id> <title> <environment-id>
  task-policy <workspace> <task-id> <derive:true|false> <followup:true|false> <depth>
  task-candidate-propose <workspace> <parent-task-id> <title> <draft-file>
             <objective-ids-csv> <knowledge-ids-csv> <reference-ids-csv> <reason>
  task-candidate-dispose <workspace> <candidate-id> <accept|reject>
  task-candidate-list <workspace>
  task-prompt <workspace> <task-id> <draft|meta|approve> [content-file]
  runtime-register <workspace> <descriptor-json>
             register a local verified JSON runtime descriptor
  runtime-list <workspace>
  meta-generate <workspace> <task-id> <adapter-id>
             generate a pending Meta Prompt through a verified adapter
  auto-meta-next <workspace> <environment-id> <adapter-id>
             pull and generate the next missing/stale Meta Prompt exactly once
  notification-register <workspace> <local-config-json>
             register local-only FCM/Hermes notification credentials
  notification-list <workspace>
             list local notification channel ids without secrets
  update-check <extracted-release-directory>
  update-apply <extracted-release-directory>
             verify and atomically apply an extracted release
  update-rollback
             swap back to the previously verified installation
  task-control <workspace> <task-id> <command> [run-id]
             request start|pause|resume|cancel|complete
  worker-next <workspace> <environment-id> <executable> [runner-arguments...]
             execute the oldest pending start request using a JSON runner
  worker-next-agent <workspace> <environment-id> <adapter-id>
             execute through a registered orchestration adapter
  worker-recover <workspace> <environment-id>
             mark expired worker runs interrupted and release stale claims
  control-disposition <workspace> <request-id> <accepted|rejected|withdrawn|expired|superseded>
  invocation-record <workspace> <run-id> <skill-id> <round> <sequence> <status>
  review-record <workspace> <run-id> <score> <independent:true|false>
  git-status <workspace>
  git-pull <workspace>
  git-sync <workspace> [commit-message]
             validate, secret-scan, commit, reconcile and push canonical data
  projection-rebuild <workspace> [--force]
  migrate-dry-run <workspace> <legacy-path>
  migrate-import <workspace> <legacy-path> <domain-id> <milestone-id>
             <environment-id> --approve
  migrate-rollback <workspace> <import-id>
  doctor     verify workspace and report locked capabilities
''');
    return;
  }
  if (arguments.first == 'hermes-meta-adapter') {
    await runHermesMetaPromptAdapter(
      hermesExecutable: Platform.environment['UNDER_CLAW_HERMES_BIN'],
    );
    return;
  }
  if (arguments.first == 'update-check' ||
      arguments.first == 'update-apply' ||
      arguments.first == 'update-rollback') {
    final service = ReleaseUpdateService();
    if (arguments.first == 'update-rollback') {
      stdout.writeln(await service.rollback());
      return;
    }
    if (arguments.length != 2) {
      throw const FormatException(
        'update-check/update-apply requires an extracted release directory.',
      );
    }
    final release = Directory(arguments[1]);
    if (arguments.first == 'update-check') {
      final status = await service.check(release);
      stdout.writeln(
        'current=${status.currentVersion} candidate=${status.candidateVersion} '
        'update_available=${status.updateAvailable}',
      );
    } else {
      stdout.writeln(await service.apply(release));
    }
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
      case 'env-register':
        if (arguments.length < 3) {
          throw const FormatException(
            'env-register requires workspace and alias.',
          );
        }
        List<String> csv(String value) => value
            .split(',')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList();
        final record = EnvironmentService(workspace).register(
          identity: EnvironmentIdentity.detect(workspace),
          alias: arguments[2],
          kind: arguments.length > 3 ? arguments[3] : 'desktop',
          capabilities: arguments.length > 4
              ? csv(arguments[4])
              : const ['git'],
        );
        stdout.writeln(
          '${record.id}\t${record.alias}\t${record.os}\t${record.kind}\t'
          '${record.status}',
        );
      case 'env-list':
        for (final record in EnvironmentService(workspace).list()) {
          stdout.writeln(
            '${record.id}\t${record.alias}\t${record.os}\t'
            '${record.architecture}\t${record.kind}\t${record.status}\t'
            'caps=${record.capabilities.join(",")}',
          );
        }
      case 'env-rename':
        if (arguments.length < 4) {
          throw const FormatException(
            'env-rename requires workspace, env id and alias.',
          );
        }
        final record = EnvironmentService(
          workspace,
        ).rename(arguments[2], arguments[3]);
        stdout.writeln('${record.id}\t${record.alias}');
      case 'env-set-kind':
        if (arguments.length < 4) {
          throw const FormatException(
            'env-set-kind requires workspace, env id and kind.',
          );
        }
        final record = EnvironmentService(
          workspace,
        ).setKind(arguments[2], arguments[3]);
        stdout.writeln('${record.id}\t${record.kind}');
      case 'env-set-capabilities':
        if (arguments.length < 4) {
          throw const FormatException(
            'env-set-capabilities requires workspace, env id and CSV.',
          );
        }
        final record = EnvironmentService(workspace).setCapabilities(
          arguments[2],
          arguments[3]
              .split(',')
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .toList(),
        );
        stdout.writeln('${record.id}\tcaps=${record.capabilities.join(",")}');
      case 'env-deactivate':
        if (arguments.length < 3) {
          throw const FormatException(
            'env-deactivate requires workspace and env id.',
          );
        }
        final record = EnvironmentService(workspace).deactivate(arguments[2]);
        stdout.writeln('${record.id}\t${record.status}');
      case 'env-activate':
        if (arguments.length < 3) {
          throw const FormatException(
            'env-activate requires workspace and env id.',
          );
        }
        final record = EnvironmentService(workspace).activate(arguments[2]);
        stdout.writeln('${record.id}\t${record.status}');
      case 'env-relink':
        if (arguments.length < 3) {
          throw const FormatException(
            'env-relink requires workspace and env id.',
          );
        }
        final record = EnvironmentService(
          workspace,
        ).relink(arguments[2], EnvironmentIdentity.detect(workspace));
        stdout.writeln('${record.id}\t${record.machineKey}');
      case 'agent-register':
        if (arguments.length < 5) {
          throw const FormatException(
            'agent-register requires workspace, name, kind and env id.',
          );
        }
        final record = AgentRegistryService(workspace).register(
          name: arguments[2],
          kind: arguments[3],
          environmentId: arguments[4],
        );
        stdout.writeln('${record.id}\t${record.name}\t${record.environmentId}');
      case 'agent-rename':
        if (arguments.length < 4) {
          throw const FormatException(
            'agent-rename requires workspace, agent id and name.',
          );
        }
        final record = AgentRegistryService(
          workspace,
        ).rename(arguments[2], arguments[3]);
        stdout.writeln('${record.id}\t${record.name}');
      case 'agent-set-kind':
        if (arguments.length < 4) {
          throw const FormatException(
            'agent-set-kind requires workspace, agent id and kind.',
          );
        }
        final record = AgentRegistryService(
          workspace,
        ).setKind(arguments[2], arguments[3]);
        stdout.writeln('${record.id}\t${record.kind}');
      case 'agent-list':
        for (final record in AgentRegistryService(workspace).list()) {
          stdout.writeln(
            '${record.id}\t${record.name}\t${record.kind}\t'
            '${record.environmentId}\t${record.status}',
          );
        }
      case 'match-propose':
        if (arguments.length < 6) {
          throw const FormatException(
            'match-propose requires workspace, subject id, target id, '
            'actor-type and actor-id [mode] [confidence] [evidence].',
          );
        }
        final record = MatchService(workspace).propose(
          subjectId: arguments[2],
          targetId: arguments[3],
          actorType: arguments[4],
          actorId: arguments[5],
          mode: arguments.length > 6 ? arguments[6] : 'manual',
          confidence: arguments.length > 7 ? num.tryParse(arguments[7]) : null,
          evidence: arguments.length > 8 ? arguments[8] : '',
        );
        projection.rebuild();
        stdout.writeln('${record.id}\t${record.reviewState}');
      case 'match-approve' || 'match-reject' || 'match-revoke':
        if (arguments.length < 5) {
          throw FormatException(
            '${arguments.first} requires workspace, match id, actor-type '
            'and actor-id [reason].',
          );
        }
        final service = MatchService(workspace);
        final id = arguments[2];
        final actorType = arguments[3];
        final actorId = arguments[4];
        final reason = arguments.length > 5 ? arguments[5] : null;
        final record = switch (arguments.first) {
          'match-approve' => service.approve(
            id,
            actorType: actorType,
            actorId: actorId,
            reason: reason,
          ),
          'match-reject' => service.reject(
            id,
            actorType: actorType,
            actorId: actorId,
            reason: reason,
          ),
          _ => service.revoke(
            id,
            actorType: actorType,
            actorId: actorId,
            reason: reason,
          ),
        };
        projection.rebuild();
        stdout.writeln('${record.id}\t${record.reviewState}');
      case 'match-list':
        for (final record in MatchService(workspace).list()) {
          stdout.writeln(
            '${record.id}\t${record.subjectId}\t${record.targetId}\t'
            '${record.matchMode}\t${record.reviewState}',
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
      case 'memory-recall':
        if (arguments.length < 4) {
          throw const FormatException(
            'memory-recall requires workspace, scope-kind '
            '(domain|milestone|task) and scope-id.',
          );
        }
        projection.rebuild();
        final scopeKind = arguments[2];
        final scopeId = arguments[3];
        // The CLI has no interactive auth session, so restricted/secret
        // Knowledge is always excluded here (fails closed).
        final recall = MemoryRecallService(workspace).recall(
          domainId: scopeKind == 'domain' ? scopeId : null,
          milestoneId: scopeKind == 'milestone' ? scopeId : null,
          taskId: scopeKind == 'task' ? scopeId : null,
        );
        stdout.writeln(
          'actors=${(recall.contributingActors.toList()..sort()).join(",")}',
        );
        for (final item in recall.current) {
          stdout.writeln(
            'current=${item.id}\tactor=${item.actorId}\t'
            'provenance=${item.provenance}\ttitle=${item.title}',
          );
        }
        for (final item in recall.superseded) {
          stdout.writeln(
            'superseded=${item.id}\tby=${item.supersededBy.join(",")}',
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
      case 'worker-next-agent':
        if (arguments.length < 4) {
          throw const FormatException(
            'worker-next-agent requires workspace, environment and adapter id.',
          );
        }
        final descriptor = InstalledRuntimeRegistry(
          workspace,
        ).require(arguments[3], capability: 'orchestration');
        final result = await TaskExecutionWorker(
          workspace: workspace,
          projection: projection,
          environmentId: arguments[2],
          remoteClaims: GitRemoteClaimService(workspace),
          runner: ProcessRunnerAdapter(
            executable: descriptor.executable,
            arguments: descriptor.fixedArguments,
            workingDirectory: workspace.root.path,
            reviewerVerifier: ExternalReviewerArtifactVerifier(
              executable: descriptor.reviewerExecutable!,
              arguments: descriptor.reviewerFixedArguments,
            ),
          ),
        ).runNext();
        if (result == null) {
          stdout.writeln('worker=idle');
        } else {
          stdout.writeln(
            'run=${result.runId}\tstatus=${result.status}\t'
            'adapter=${descriptor.id}'
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
      case 'runtime-register':
        if (arguments.length < 3) {
          throw const FormatException(
            'runtime-register requires workspace and descriptor JSON.',
          );
        }
        final decoded = jsonDecode(File(arguments[2]).readAsStringSync());
        if (decoded is! Map<String, Object?>) {
          throw const FormatException('Runtime descriptor must be an object.');
        }
        final descriptor = InstalledRuntimeDescriptor.fromJson(decoded);
        InstalledRuntimeRegistry(workspace).register(descriptor);
        stdout.writeln(
          'runtime=${descriptor.id} capabilities='
          '${(descriptor.capabilities.toList()..sort()).join(",")}',
        );
      case 'runtime-list':
        for (final descriptor in InstalledRuntimeRegistry(workspace).list()) {
          stdout.writeln(
            '${descriptor.id}\t${descriptor.protocol}\t'
            'capabilities=${(descriptor.capabilities.toList()..sort()).join(",")}',
          );
        }
      case 'meta-generate':
        if (arguments.length < 4) {
          throw const FormatException(
            'meta-generate requires workspace, task id and adapter id.',
          );
        }
        final result = await MetaPromptService(
          workspace,
        ).generate(taskId: arguments[2], adapterId: arguments[3]);
        projection.rebuild();
        stdout.writeln(
          'task=${result.task.id} approval=${result.task.approval.name} '
          'adapter=${result.adapterId} output_sha256=${result.outputSha256}',
        );
      case 'auto-meta-next':
        if (arguments.length < 4) {
          throw const FormatException(
            'auto-meta-next requires workspace, environment id and adapter id.',
          );
        }
        await GitSyncService(workspace).pullFastForward();
        final notificationRegistry = NotificationChannelRegistry(workspace);
        MetaReadyNotifier notifier = const NoopMetaReadyNotifier();
        if (notificationRegistry.list().isNotEmpty) {
          final queuedNotifier = QueuedMetaReadyNotifier(
            workspace,
            HttpMetaReadyNotifier(notificationRegistry),
          );
          await queuedNotifier.retryPending();
          notifier = queuedNotifier;
        }
        final result = await AutoMetaWorker(
          workspace: workspace,
          environmentId: arguments[2],
          adapterId: arguments[3],
          claims: GitRemoteClaimService(workspace),
          notifier: notifier,
        ).runNext();
        projection.rebuild();
        if (result == null) {
          stdout.writeln('auto_meta=idle');
        } else {
          stdout.writeln(
            'auto_meta=${result.status.name} task=${result.taskId} '
            'output_sha256=${result.outputSha256}',
          );
        }
      case 'notification-register':
        if (arguments.length < 3) {
          throw const FormatException(
            'notification-register requires workspace and local config JSON.',
          );
        }
        final registry = NotificationChannelRegistry(workspace);
        registry.registerFrom(File(arguments[2]));
        stdout.writeln('notification_channels=${registry.list().length}');
      case 'notification-list':
        for (final channel in NotificationChannelRegistry(workspace).list()) {
          stdout.writeln(
            '${channel.id}\t${channel.kind.name}\t'
            'targets=${channel.kind == NotificationChannelKind.fcm ? channel.tokens.length : 1}',
          );
        }
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
      case 'git-sync':
        final report = await CanonicalSyncService(workspace).syncCanonical(
          message: arguments.length > 2
              ? arguments.skip(2).join(' ')
              : 'worklog: sync canonical data',
          verifier: const CanonicalSecretVerifier(),
        );
        projection.rebuild();
        stdout.writeln(
          'sync=ok before=${report.beforeHead} after=${report.afterHead} '
          'committed=${report.committed} rebased=${report.rebased} '
          'pushed=${report.pushed}',
        );
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
