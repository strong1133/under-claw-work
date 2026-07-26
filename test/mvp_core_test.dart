import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late ProjectionStore projection;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-mvp-');
    workspace = Workspace(temporary)..ensureLayout();
    projection = ProjectionStore(workspace);
  });

  tearDown(() {
    projection.dispose();
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('Task Draft Meta approval lifecycle is canonical', () {
    final tasks = TaskRepository(workspace);
    var task = tasks.create(_task(status: TaskStatus.draft));
    task = tasks.saveDraft(task, 'Changed Draft');
    expect(task.approval, PromptApproval.stale);
    task = ManualMetaPromptService(workspace)
        .recordCompleted(
          taskId: task.id,
          metaPrompt: 'Generated Meta',
          evidence: _metaEvidence(task, 'Generated Meta'),
        )
        .task;
    expect(task.approval, PromptApproval.pending);
    task = tasks.approveMeta(task);
    expect(task.isMetaCurrent, isTrue);
    expect(task.status, TaskStatus.ready);
    expect(TaskRepository(workspace).get(task.id)!.isMetaCurrent, isTrue);
  });

  test('all controls are immutable, idempotent and state checked', () {
    final repository = TaskRepository(workspace);
    final ready = repository.create(_task());
    final service = ControlService(workspace, projection);
    final run = service.requestStart(ready, 'OPR-start');
    expect(service.requestStart(ready, 'OPR-start'), run);
    final running = ready.copyWith(status: TaskStatus.running);
    final pause = service.request(
      running,
      ControlCommand.pause,
      operationId: 'OPR-pause',
      runId: run,
    );
    expect(pause, run);
    expect(
      () => service.request(
        ready,
        ControlCommand.complete,
        operationId: 'OPR-invalid',
        runId: run,
      ),
      throwsStateError,
    );
    expect(
      CanonicalRepository(workspace).list(EntityKind.controlRequest),
      hasLength(2),
    );
  });

  test('claim heartbeat and expired takeover are deterministic', () {
    final service = ClaimService(workspace, projection);
    final start = DateTime.utc(2026, 7, 23);
    final first = service.acquire(
      taskId: 'TSK-example',
      runId: 'RUN-one',
      environmentId: 'ENV-one',
      ttl: const Duration(seconds: 10),
      now: start,
    );
    expect(
      () => service.acquire(
        taskId: 'TSK-example',
        runId: 'RUN-two',
        environmentId: 'ENV-two',
        now: start.add(const Duration(seconds: 5)),
      ),
      throwsStateError,
    );
    service.heartbeat(first.id, now: start.add(const Duration(seconds: 5)));
    final second = service.acquire(
      taskId: 'TSK-example',
      runId: 'RUN-two',
      environmentId: 'ENV-two',
      now: start.add(const Duration(minutes: 6)),
    );
    expect(second.id, first.id);
    expect(second.data['environment_id'], 'ENV-two');
  });

  test('corrupt SQLite is automatically discarded and rebuilt', () {
    TaskRepository(workspace).create(_task());
    workspace.database.writeAsStringSync('not a sqlite database');
    expect(projection.rebuild(), hasLength(1));
  });

  test(
    'real process adapter validates output and persists canonical audit',
    () async {
      final task = TaskRepository(workspace).create(_task());
      File(
        '${workspace.root.path}/reviewer-RUN-process.json',
      ).writeAsStringSync(
        '{"run_id":"RUN-process","session_id":"review-session-process",'
        '"producer_session_id":"producer-session-process",'
        '"reviewer_score":9.5,"independent_reviewer":true}',
        flush: true,
      );
      final payload =
          '''
{"trace":[
 {"skill_id":"under-claw-meta-prompt","round":0},
 {"skill_id":"under-claw-jarvis-plan-loop","round":0},
 {"skill_id":"under-claw-jarvis-plan","round":1}
],"producer_session_id":"producer-session-process",
"reviewer_artifact_path":"reviewer-RUN-process.json"}
'''
              .replaceAll('\n', '');
      final runner = ProcessRunnerAdapter(
        executable: Platform.isWindows ? 'powershell.exe' : '/bin/sh',
        arguments: Platform.isWindows
            ? ['-NoProfile', '-Command', "[Console]::Out.Write('$payload')"]
            : ['-c', "printf '%s' '$payload'"],
        workingDirectory: workspace.root.path,
        reviewerVerifier: _TestOnlyReviewerVerifier(),
      );
      await SkillPipeline(projection, runner).execute(task, 'RUN-process');
      final canonical = CanonicalRepository(workspace);
      expect(canonical.list(EntityKind.invocation), hasLength(4));
      projection.dispose();
      workspace.database.deleteSync();
      projection = ProjectionStore(workspace);
      projection.rebuild();
      expect(
        projection.open().select(
          'SELECT skill_id FROM skill_invocations WHERE run_id = ?',
          ['RUN-process'],
        ),
        hasLength(4),
      );
    },
  );

  test('process adapter rejects producer acting as reviewer', () async {
    File(p.join(workspace.root.path, 'same-session.json')).writeAsStringSync(
      '{"run_id":"RUN-same","session_id":"same",'
      '"producer_session_id":"same","reviewer_score":10,'
      '"independent_reviewer":true}',
    );
    final payload =
        '{"trace":[],"producer_session_id":"same",'
        '"reviewer_artifact_path":"same-session.json"}';
    final runner = _processForPayload(workspace, payload);

    expect(
      runner.invokeOrchestration(
        const SkillInvocation('under-claw-jarvis-plan-loop', 'RUN-same', 0),
      ),
      throwsFormatException,
    );
  });

  test(
    'process adapter rejects reviewer artifact symlink components',
    () async {
      if (Platform.isWindows) return;
      final real = Directory(p.join(workspace.root.path, 'real-review'))
        ..createSync();
      File(p.join(real.path, 'artifact.json')).writeAsStringSync(
        '{"run_id":"RUN-link","session_id":"reviewer",'
        '"producer_session_id":"producer","reviewer_score":10,'
        '"independent_reviewer":true}',
      );
      Link(p.join(workspace.root.path, 'linked-review')).createSync(real.path);
      final runner = _processForPayload(
        workspace,
        '{"trace":[],"producer_session_id":"producer",'
        '"reviewer_artifact_path":"linked-review/artifact.json"}',
      );

      expect(
        runner.invokeOrchestration(
          const SkillInvocation('under-claw-jarvis-plan-loop', 'RUN-link', 0),
        ),
        throwsFormatException,
      );
    },
  );

  test('Git optimistic head rejects stale writer', () async {
    final root = Directory(p.join(temporary.path, 'git-work'))..createSync();
    await _git(root, ['init']);
    await _git(root, ['config', 'user.email', 'example@example.invalid']);
    await _git(root, ['config', 'user.name', 'Example']);
    final gitWorkspace = Workspace(root)..ensureLayout();
    File(p.join(root.path, '.gitignore')).writeAsStringSync('.worklog/\n');
    await _git(root, ['add', '.']);
    await _git(root, ['commit', '-m', 'initial']);
    final service = GitSyncService(gitWorkspace);
    final head = (await service.status(fetch: false)).head;
    File(
      p.join(gitWorkspace.config.path, 'example.txt'),
    ).writeAsStringSync('change');
    await _git(root, ['add', '.']);
    await _git(root, ['commit', '-m', 'concurrent']);
    expect(
      service.commitAndPush(expectedHead: head, message: 'stale'),
      throwsStateError,
    );
  });

  test('two clones fast-forward and reject a competing push', () async {
    final bare = Directory(p.join(temporary.path, 'remote.git'));
    await _git(temporary, ['init', '--bare', bare.path]);
    final seed = Directory(p.join(temporary.path, 'seed'));
    await _git(temporary, ['clone', bare.path, seed.path]);
    await _identity(seed);
    final seedWorkspace = Workspace(seed)..ensureLayout();
    File(p.join(seed.path, '.gitignore')).writeAsStringSync('.worklog/\n');
    TaskRepository(seedWorkspace).create(_task());
    await _git(seed, ['add', '.']);
    await _git(seed, ['commit', '-m', 'seed']);
    await _git(seed, ['push', '-u', 'origin', 'HEAD']);

    final first = Directory(p.join(temporary.path, 'first'));
    final second = Directory(p.join(temporary.path, 'second'));
    await _git(temporary, ['clone', bare.path, first.path]);
    await _git(temporary, ['clone', bare.path, second.path]);
    await _identity(first);
    await _identity(second);
    final firstService = GitSyncService(Workspace(first));
    final secondService = GitSyncService(Workspace(second));
    final firstHead = (await firstService.status()).head;
    File(p.join(first.path, 'workdb', 'config', 'first.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('first');
    await firstService.commitAndPush(
      expectedHead: firstHead,
      message: 'first change',
    );
    expect((await secondService.status()).state, GitSyncState.behind);
    await secondService.pullFastForward();
    expect((await secondService.status()).state, GitSyncState.clean);

    final competingHead = (await secondService.status()).head;
    File(
      p.join(second.path, 'workdb', 'config', 'second.txt'),
    ).writeAsStringSync('second');
    File(
      p.join(first.path, 'workdb', 'config', 'winner.txt'),
    ).writeAsStringSync('winner');
    await firstService.commitAndPush(
      expectedHead: (await firstService.status()).head,
      message: 'winner',
    );
    expect(
      secondService.commitAndPush(
        expectedHead: competingHead,
        message: 'loser',
      ),
      throwsStateError,
    );
  });

  test('two clones acquire exactly one remote task claim', () async {
    final bare = Directory(p.join(temporary.path, 'claim-remote.git'));
    await _git(temporary, ['init', '--bare', bare.path]);
    final seed = Directory(p.join(temporary.path, 'claim-seed'));
    await _git(temporary, ['clone', bare.path, seed.path]);
    await _identity(seed);
    File(p.join(seed.path, 'README.md')).writeAsStringSync('seed\n');
    await _git(seed, ['add', '.']);
    await _git(seed, ['commit', '-m', 'seed']);
    await _git(seed, ['push', '-u', 'origin', 'HEAD']);
    final first = Directory(p.join(temporary.path, 'claim-first'));
    final second = Directory(p.join(temporary.path, 'claim-second'));
    await _git(temporary, ['clone', bare.path, first.path]);
    await _git(temporary, ['clone', bare.path, second.path]);
    await _identity(first);
    await _identity(second);

    final leases = await Future.wait([
      GitRemoteClaimService(Workspace(first)).tryAcquire(
        taskId: 'TSK-race',
        runId: 'RUN-first',
        environmentId: 'ENV-first',
      ),
      GitRemoteClaimService(Workspace(second)).tryAcquire(
        taskId: 'TSK-race',
        runId: 'RUN-second',
        environmentId: 'ENV-second',
      ),
    ]);

    expect(leases.whereType<RemoteClaimLease>(), hasLength(1));
    final winner = leases.whereType<RemoteClaimLease>().single;
    final winnerRoot = winner.environmentId == 'ENV-first' ? first : second;
    final loserRoot = winner.environmentId == 'ENV-first' ? second : first;
    final renewed = await GitRemoteClaimService(
      Workspace(winnerRoot),
    ).renew(winner, ttl: const Duration(minutes: 10));
    expect(renewed, isNotNull);
    expect(
      await GitRemoteClaimService(Workspace(winnerRoot)).release(winner),
      isFalse,
    );
    final takeover = await GitRemoteClaimService(Workspace(loserRoot)).takeover(
      renewed!,
      runId: 'RUN-takeover',
      environmentId: 'ENV-takeover',
      now: renewed.expiresAt.add(const Duration(seconds: 1)),
    );
    expect(takeover, isNotNull);
    expect(
      await GitRemoteClaimService(Workspace(winnerRoot)).release(renewed),
      isFalse,
    );
    expect(
      await GitRemoteClaimService(Workspace(loserRoot)).release(takeover!),
      isTrue,
    );
  });

  test('host discovery is provider-neutral and reports connections', () {
    final home = Directory(p.join(temporary.path, 'home'))..createSync();
    Directory(
      p.join(home.path, '.codex', 'skills', 'under-claw-work-plan'),
    ).createSync(recursive: true);
    Directory(p.join(home.path, '.hermes')).createSync(recursive: true);

    final hosts = HostDiscoveryService(
      userHome: home.path,
      environment: const {},
      executableExists: (_) => false,
    ).discover();

    expect(
      hosts.singleWhere((host) => host.host == AgentHost.codex).connected,
      isTrue,
    );
    expect(
      hosts.singleWhere((host) => host.host == AgentHost.hermes).detected,
      isTrue,
    );
    expect(
      hosts.singleWhere((host) => host.host == AgentHost.claudeCode).detected,
      isFalse,
    );
  });
}

Map<String, Object?> _metaEvidence(WorkTask task, String meta) => {
  'protocol': 'under-claw-meta-evidence/v1',
  'skill_id': 'under-claw-meta-prompt',
  'bundle_version': 'test',
  'bundle_checksum': 'a' * 64,
  'host_invocation_id': 'test-${task.id}-${task.promptDraftRevision}',
  'host_id': 'test',
  'runner_id': 'test',
  'source_revision': task.promptDraftRevision,
  'source_sha256': TaskRepository.draftSha256(task.promptDraft),
  'started_at': '2026-07-26T01:00:00Z',
  'finished_at': '2026-07-26T01:01:00Z',
  'status': 'completed',
  'result_sha256': TaskRepository.draftSha256(meta),
  'result_ref': 'task:${task.id}#meta@${task.promptDraftRevision}',
};

WorkTask _task({TaskStatus status = TaskStatus.ready}) {
  return WorkTask(
    id: 'TSK-example',
    domainId: 'DOM-example',
    milestoneId: 'MLS-example',
    title: 'Example Task',
    status: status,
    promptDraft: 'Draft',
    promptMeta: 'Meta',
    promptDraftRevision: 1,
    promptMetaSourceRevision: 1,
    promptMetaSourceSha256: TaskRepository.draftSha256('Draft'),
    approval: PromptApproval.approved,
    autoDeriveTasks: true,
    targetEnvironment: 'ENV-local',
  );
}

ProcessRunnerAdapter _processForPayload(Workspace workspace, String payload) {
  return ProcessRunnerAdapter(
    executable: Platform.isWindows ? 'powershell.exe' : '/bin/sh',
    arguments: Platform.isWindows
        ? ['-NoProfile', '-Command', "[Console]::Out.Write('$payload')"]
        : ['-c', "printf '%s' '$payload'"],
    workingDirectory: workspace.root.path,
    reviewerVerifier: _TestOnlyReviewerVerifier(),
  );
}

class _TestOnlyReviewerVerifier implements ReviewerArtifactVerifier {
  @override
  Future<bool> verify({
    required String producerSessionId,
    required String reviewerSessionId,
    required List<int> artifactBytes,
  }) async =>
      producerSessionId != reviewerSessionId && artifactBytes.isNotEmpty;
}

Future<void> _git(Directory directory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: directory.path,
  );
  if (result.exitCode != 0) {
    throw ProcessException('git', arguments, result.stderr.toString());
  }
}

Future<void> _identity(Directory directory) async {
  await _git(directory, ['config', 'user.email', 'example@example.invalid']);
  await _git(directory, ['config', 'user.name', 'Example']);
}
