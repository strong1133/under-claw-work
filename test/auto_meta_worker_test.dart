import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/auto_meta_worker.dart';
import 'package:under_claw_work/core/canonical_repository.dart';

import 'package:under_claw_work/core/git_remote_claim_service.dart';
import 'package:under_claw_work/core/installed_runtime_registry.dart';
import 'package:under_claw_work/core/meta_prompt_service.dart';
import 'package:under_claw_work/core/models.dart';
import 'package:under_claw_work/core/notification_service.dart';
import 'package:under_claw_work/core/schema_validator.dart';
import 'package:under_claw_work/core/task_repository.dart';
import 'package:under_claw_work/core/workspace.dart';

void main() {
  late Directory root;
  late Workspace workspace;
  late InstalledRuntimeRegistry runtimes;
  late File adapter;

  setUp(() {
    root = Directory.systemTemp.createTempSync('auto-meta-worker-');
    workspace = Workspace(root)..ensureLayout();
    runtimes = InstalledRuntimeRegistry(workspace);
    adapter = File(p.join(root.path, 'meta-adapter.dart'));
    _writeAdapter(adapter);
    final dart = File(_dartExecutable());
    runtimes.register(
      InstalledRuntimeDescriptor(
        id: 'test-meta',
        protocol: InstalledRuntimeDescriptor.protocolV1,
        executable: dart.path,
        fixedArguments: [adapter.path],
        capabilities: const {'generate_meta'},
        executableSha256: sha256.convert(dart.readAsBytesSync()).toString(),
      ),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('generates and publishes pending Meta for an eligible Draft', () async {
    TaskRepository(workspace).create(_task());
    final claims = _FakeClaims();
    final publisher = _RecordingPublisher();
    final notifier = _RecordingNotifier();
    final worker = AutoMetaWorker(
      workspace: workspace,
      environmentId: 'ENV-astro',
      adapterId: 'test-meta',
      claims: claims,
      generator: MetaPromptService(workspace, runtimes: runtimes),
      publisher: publisher,
      notifier: notifier,
    );

    final result = await worker.runNext();

    expect(result?.taskId, 'TSK-auto-meta');
    expect(result?.status, AutoMetaRunStatus.generated);
    final updated = TaskRepository(workspace).get('TSK-auto-meta')!;
    expect(updated.promptMeta, 'META: Draft request');
    expect(updated.promptMetaSourceRevision, 1);
    expect(
      updated.promptMetaSourceSha256,
      TaskRepository.draftSha256('Draft request'),
    );
    expect(updated.approval, PromptApproval.pending);
    expect(publisher.messages, hasLength(2));
    expect(notifier.notifications.single.taskId, 'TSK-auto-meta');
    expect(notifier.notifications.single.sourceRevision, 1);
    expect(claims.released, isTrue);
    expect(claims.renewed, 2);
    expect(CanonicalRepository(workspace).list(EntityKind.run), hasLength(1));
    expect(
      CanonicalRepository(workspace).list(EntityKind.invocation),
      hasLength(1),
    );
    expect(CanonicalRepository(workspace).list(EntityKind.event), hasLength(2));
  });

  test('treats missing or stale Meta as eligible but not pending Meta', () {
    final missing = _task();
    final stale = missing.copyWith(
      promptMeta: 'old',
      promptDraftRevision: 2,
      promptMetaSourceRevision: 1,
      approval: PromptApproval.stale,
    );
    final pending = missing.copyWith(
      promptMeta: 'current',
      promptMetaSourceRevision: 1,
      promptMetaSourceSha256: TaskRepository.draftSha256('Draft request'),
      approval: PromptApproval.pending,
    );
    final legacyPendingWithoutHash = missing.copyWith(
      promptMeta: 'legacy current',
      promptMetaSourceRevision: 1,
      approval: PromptApproval.pending,
    );
    final contentChangedWithoutRevision = pending.copyWith(
      promptDraft: 'Draft changed outside the CLI',
    );

    expect(AutoMetaWorker.isEligible(missing), isTrue);
    expect(AutoMetaWorker.isEligible(stale), isTrue);
    expect(AutoMetaWorker.isEligible(pending), isFalse);
    expect(AutoMetaWorker.isEligible(legacyPendingWithoutHash), isTrue);
    expect(AutoMetaWorker.isEligible(contentChangedWithoutRevision), isTrue);
    expect(
      AutoMetaWorker.isEligible(
        missing.copyWith(promptDraft: '', approval: PromptApproval.missing),
      ),
      isFalse,
    );
  });

  test('does not generate when another environment owns the claim', () async {
    TaskRepository(workspace).create(_task());
    final publisher = _RecordingPublisher();
    final notifier = _RecordingNotifier();
    final worker = AutoMetaWorker(
      workspace: workspace,
      environmentId: 'ENV-astro',
      adapterId: 'test-meta',
      claims: _FakeClaims(acquire: false),
      generator: MetaPromptService(workspace, runtimes: runtimes),
      publisher: publisher,
      notifier: notifier,
    );

    final result = await worker.runNext();

    expect(result, isNull);
    expect(TaskRepository(workspace).get('TSK-auto-meta')!.promptMeta, isEmpty);
    expect(publisher.messages, isEmpty);
    expect(notifier.notifications, isEmpty);
  });

  test('publishes Meta even when notification delivery fails', () async {
    TaskRepository(workspace).create(_task());
    final publisher = _RecordingPublisher();
    final worker = AutoMetaWorker(
      workspace: workspace,
      environmentId: 'ENV-astro',
      adapterId: 'test-meta',
      claims: _FakeClaims(),
      generator: MetaPromptService(workspace, runtimes: runtimes),
      publisher: publisher,
      notifier: _FailingNotifier(),
    );

    final result = await worker.runNext();

    expect(result?.status, AutoMetaRunStatus.generatedWithNotificationFailure);
    expect(
      TaskRepository(workspace).get('TSK-auto-meta')!.approval,
      PromptApproval.pending,
    );
    expect(publisher.messages, hasLength(2));
  });

  test('publishes durable start evidence before a failed adapter', () async {
    TaskRepository(workspace).create(_task());
    adapter.writeAsStringSync("void main() { print('invalid'); }\n");
    final publisher = _RecordingPublisher();
    final worker = AutoMetaWorker(
      workspace: workspace,
      environmentId: 'ENV-astro',
      adapterId: 'test-meta',
      claims: _FakeClaims(),
      generator: MetaPromptService(workspace, runtimes: runtimes),
      publisher: publisher,
    );

    await expectLater(worker.runNext(), throwsFormatException);

    expect(publisher.messages, hasLength(2));
    expect(TaskRepository(workspace).get('TSK-auto-meta')!.promptMeta, isEmpty);
    final events = CanonicalRepository(workspace).list(EntityKind.event);
    expect(events, hasLength(2));
    final eventTypes = events.map((event) => event.data['event_type']).toSet();
    expect(eventTypes, {
      'meta_prompt_generation_started',
      'meta_prompt_generation_failed',
    });
    final failure = events.singleWhere(
      (event) => event.data['event_type'] == 'meta_prompt_generation_failed',
    );
    expect(failure.data['error_type'], 'FormatException');
    expect(
      CanonicalRepository(workspace).list(EntityKind.run).single.data['status'],
      'failed',
    );
    expect(
      CanonicalRepository(
        workspace,
      ).list(EntityKind.invocation).single.data['status'],
      'failed',
    );
    final validator = WorklogContractValidator();
    for (final kind in [
      EntityKind.event,
      EntityKind.run,
      EntityKind.invocation,
    ]) {
      for (final entity in CanonicalRepository(workspace).list(kind)) {
        validator.validateEntity(entity);
      }
    }
  });
}

class _FakeClaims implements RemoteClaimProvider {
  _FakeClaims({this.acquire = true});

  final bool acquire;
  bool released = false;
  int renewed = 0;

  @override
  Future<RemoteClaimLease?> tryAcquire({
    required String taskId,
    required String runId,
    required String environmentId,
    required Duration ttl,
    DateTime? now,
  }) async => acquire
      ? RemoteClaimLease(
          taskId: taskId,
          runId: runId,
          environmentId: environmentId,
          ref: 'refs/test/$taskId',
          objectId: 'a' * 40,
          epoch: 1,
          expiresAt: DateTime.now().toUtc().add(ttl),
        )
      : null;

  @override
  Future<bool> isCurrent(RemoteClaimLease lease) async => true;

  @override
  Future<bool> release(RemoteClaimLease lease) async {
    released = true;
    return true;
  }

  @override
  Future<RemoteClaimLease?> renew(
    RemoteClaimLease lease, {
    required Duration ttl,
    DateTime? now,
  }) async {
    renewed++;
    return lease;
  }
}

class _RecordingPublisher implements CanonicalMetaPublisher {
  final messages = <String>[];

  @override
  Future<void> publish(String message, RemoteClaimLease lease) async =>
      messages.add(message);
}

class _RecordingNotifier implements MetaReadyNotifier {
  final notifications = <MetaReadyNotification>[];

  @override
  Future<NotificationDeliveryReport> notifyMetaReady(
    MetaReadyNotification notification,
  ) async {
    notifications.add(notification);
    return const NotificationDeliveryReport(delivered: 1, failed: 0);
  }
}

class _FailingNotifier implements MetaReadyNotifier {
  @override
  Future<NotificationDeliveryReport> notifyMetaReady(
    MetaReadyNotification notification,
  ) async => throw StateError('notification unavailable');
}

String _dartExecutable() {
  final result = Process.runSync(Platform.isWindows ? 'where' : 'which', const [
    'dart',
  ]);
  if (result.exitCode != 0) throw StateError('Dart executable not found.');
  return File(
    result.stdout.toString().split(RegExp(r'\r?\n')).first.trim(),
  ).resolveSymbolicLinksSync();
}

void _writeAdapter(File file) {
  file.writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final input = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  stdout.write(jsonEncode({
    'protocol': 'under-claw-json-v1',
    'type': 'meta_prompt_result',
    'task_id': input['task_id'],
    'source_revision': input['source_revision'],
    'source_sha256': input['source_sha256'],
    'meta_prompt': 'META: ${input['draft']}',
  }));
}
''');
}

WorkTask _task() => const WorkTask(
  id: 'TSK-auto-meta',
  domainId: 'DOM-auto',
  milestoneId: 'MLS-auto',
  title: 'Auto Meta task',
  status: TaskStatus.draft,
  promptDraft: 'Draft request',
  promptMeta: '',
  promptDraftRevision: 1,
  promptMetaSourceRevision: 0,
  approval: PromptApproval.missing,
  autoDeriveTasks: false,
  targetEnvironment: 'ENV-astro',
);
