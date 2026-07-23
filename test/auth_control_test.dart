import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  group('repository authentication boundary', () {
    const context = AuthContext(
      repositoryId: 'repo-example',
      policyVersion: 2,
      environmentId: 'ENV-example',
    );

    test('accepted provider returns only a bound short-lived grant', () async {
      final now = DateTime.utc(2026, 7, 23);
      final provider = _FakeProvider(now);
      final gate = RepositoryAuthGate(
        status: AuthProviderStatus.accepted,
        provider: provider,
        clock: () => now,
      );

      final grant = await gate.unlock(context, 'fixture-password');

      expect(provider.lastPasswordLength, 16);
      expect(grant.isValidFor(context, now), isTrue);
      expect(gate.sessionFor(context), same(grant));
      gate.lock();
      expect(gate.sessionFor(context), isNull);
    });

    test('wrongly bound provider grant is rejected', () async {
      final now = DateTime.utc(2026, 7, 23);
      final gate = RepositoryAuthGate(
        status: AuthProviderStatus.accepted,
        provider: _FakeProvider(now, wrongRepository: true),
        clock: () => now,
      );
      await expectLater(
        gate.unlock(context, 'fixture-password'),
        throwsA(isA<AuthUnavailable>()),
      );
    });

    test(
      'failed online attempts lock only the repository environment',
      () async {
        var now = DateTime.utc(2026, 7, 23);
        final gate = RepositoryAuthGate(
          status: AuthProviderStatus.accepted,
          provider: _FakeProvider(now, reject: true),
          clock: () => now,
          maximumAttempts: 2,
          lockout: const Duration(minutes: 10),
        );
        for (var index = 0; index < 2; index++) {
          await expectLater(
            gate.unlock(context, 'wrong-password'),
            throwsA(isA<StateError>()),
          );
        }
        await expectLater(
          gate.unlock(context, 'wrong-password'),
          throwsA(isA<AuthRateLimited>()),
        );
        now = now.add(const Duration(minutes: 11));
        await expectLater(
          gate.unlock(context, 'wrong-password'),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('control disposition lifecycle', () {
    late Directory temporary;
    late Workspace workspace;
    late ProjectionStore projection;
    late WorkTask task;

    setUp(() {
      temporary = Directory.systemTemp.createTempSync('under-claw-control-');
      workspace = Workspace(temporary)..ensureLayout();
      projection = ProjectionStore(workspace);
      task = TaskRepository(workspace).create(
        const WorkTask(
          id: 'TSK-control',
          domainId: 'DOM-example',
          milestoneId: 'MLS-example',
          title: 'Control task',
          status: TaskStatus.ready,
          promptDraft: 'Draft',
          promptMeta: 'Meta',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 1,
          approval: PromptApproval.approved,
          autoDeriveTasks: false,
          targetEnvironment: 'ENV-example',
        ),
      );
    });

    tearDown(() {
      projection.dispose();
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    });

    test(
      'withdraw wins one fixed disposition path and aborts reserved run',
      () {
        final service = ControlService(workspace, projection);
        final runId = service.requestStart(task, 'OPR-withdraw');
        final request = CanonicalRepository(
          workspace,
        ).list(EntityKind.controlRequest).single;

        final disposition = service.withdraw(request.id);

        expect(disposition.id, 'EVT-${request.id.substring(4)}');
        expect(
          service.dispositionFor(request.id)?.data['disposition'],
          'withdrawn',
        );
        expect(
          CanonicalRepository(
            workspace,
          ).get(EntityKind.run, runId)?.data['status'],
          'aborted_before_start',
        );
        expect(
          () => service.addDisposition(request.id, 'accepted'),
          throwsFormatException,
        );
        expect(
          TaskRepository(workspace).get(task.id)?.status,
          TaskStatus.ready,
        );
      },
    );

    test('accepted disposition alone never transitions task or run', () {
      final service = ControlService(workspace, projection);
      final runId = service.requestStart(task, 'OPR-accept');
      final request = CanonicalRepository(
        workspace,
      ).list(EntityKind.controlRequest).single;

      service.addDisposition(request.id, 'accepted');

      expect(TaskRepository(workspace).get(task.id)?.status, TaskStatus.ready);
      expect(
        CanonicalRepository(
          workspace,
        ).get(EntityKind.run, runId)?.data['status'],
        'requested',
      );
    });
  });
}

class _FakeProvider implements RepositoryAuthProvider {
  _FakeProvider(this.now, {this.reject = false, this.wrongRepository = false});

  final DateTime now;
  final bool reject;
  final bool wrongRepository;
  int? lastPasswordLength;

  @override
  String get providerId => 'test-only';

  @override
  Future<AuthGrant> authenticate(AuthContext context, String password) async {
    lastPasswordLength = password.length;
    if (reject) throw StateError('AUTHENTICATION_FAILED');
    return _grant(context);
  }

  @override
  Future<AuthGrant> register(AuthContext context, String password) =>
      authenticate(context, password);

  @override
  Future<AuthGrant> rotate(
    AuthContext context,
    String currentPassword,
    String newPassword,
  ) => authenticate(context, newPassword);

  AuthGrant _grant(AuthContext context) => AuthGrant(
    id: 'grant-example',
    repositoryId: wrongRepository ? 'repo-other' : context.repositoryId,
    policyVersion: context.policyVersion,
    environmentId: context.environmentId,
    expiresAt: now.add(const Duration(minutes: 5)),
  );
}
