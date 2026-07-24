import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Directory remote;
  late Directory local;
  late Workspace workspace;
  late String branch;

  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('canonical-sync-');
    remote = Directory(p.join(temporary.path, 'remote.git'));
    await _git(temporary.path, ['init', '--bare', remote.path]);
    local = Directory(p.join(temporary.path, 'local'));
    await _git(temporary.path, ['clone', remote.path, local.path]);
    await _identity(local.path);
    workspace = Workspace(local)..ensureLayout();
    File(p.join(local.path, '.gitignore')).writeAsStringSync('.worklog/\n');
    EntityService(workspace).create(kind: EntityKind.domain, title: 'Initial');
    await _git(local.path, ['add', '.gitignore', 'workdb']);
    await _git(local.path, ['commit', '-m', 'initial']);
    branch = await _output(local.path, ['symbolic-ref', '--short', 'HEAD']);
    await _git(local.path, ['push', '-u', 'origin', 'HEAD']);
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('publishes verified canonical worktree changes', () async {
    EntityService(workspace).create(kind: EntityKind.domain, title: 'Local');
    final verifier = _RecordingVerifier();

    final report = await CanonicalSyncService(
      workspace,
    ).syncCanonical(message: 'sync local', verifier: verifier);

    expect(report.committed, isTrue);
    expect(report.pushed, isTrue);
    expect(verifier.calls, 2);
    expect(await _output(local.path, ['status', '--porcelain']), isEmpty);
    expect(
      await _output(remote.path, ['rev-parse', 'refs/heads/$branch']),
      report.afterHead,
    );
  });

  test('reads canonical Markdown checked out with Windows line endings', () {
    final repository = CanonicalRepository(workspace);
    final domain = repository.list(EntityKind.domain).single;
    final file = repository.fileFor(EntityKind.domain, domain.id);
    file.writeAsStringSync(
      file.readAsStringSync().replaceAll('\n', '\r\n'),
      flush: true,
    );

    expect(repository.list(EntityKind.domain).single.id, domain.id);
  });

  test('publishes a tracked canonical file modified in the worktree', () async {
    final domain = CanonicalRepository(
      workspace,
    ).list(EntityKind.domain).single;
    EntityService(workspace).update(domain, title: 'Updated');

    final report = await CanonicalSyncService(workspace).syncCanonical(
      message: 'sync tracked update',
      verifier: _RecordingVerifier(),
    );

    expect(report.committed, isTrue);
    expect(report.pushed, isTrue);
    expect(await _output(local.path, ['status', '--porcelain']), isEmpty);
  });

  test('rejects and preserves a concurrent expected-file mutation', () async {
    final repository = CanonicalRepository(workspace);
    final domain = repository.list(EntityKind.domain).single;
    EntityService(workspace).update(domain, title: 'Expected');
    final file = repository.fileFor(EntityKind.domain, domain.id);
    final relative = p.posix.joinAll(
      p.relative(file.path, from: workspace.root.path).split(p.separator),
    );
    final expectedHash = sha256.convert(file.readAsBytesSync()).toString();
    final beforeHead = await _output(local.path, ['rev-parse', 'HEAD']);

    await expectLater(
      CanonicalSyncService(workspace).syncCanonical(
        message: 'must reject concurrent mutation',
        verifier: _MutatingSecondVerifier(file),
        committedFileSha256: {relative: expectedHash},
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('CANONICAL_WORKING_FILE_CHANGED'),
        ),
      ),
    );

    expect(await _output(local.path, ['rev-parse', 'HEAD']), beforeHead);
    expect(file.readAsStringSync(), contains('Concurrent'));
  });

  test('rejects a pre-existing staged index without changing it', () async {
    final note = File(p.join(local.path, 'note.txt'))
      ..writeAsStringSync('note');
    await _git(local.path, ['add', note.path]);
    final before = await _output(local.path, ['diff', '--cached', '--binary']);

    await expectLater(
      CanonicalSyncService(
        workspace,
      ).syncCanonical(message: 'must fail', verifier: _RecordingVerifier()),
      throwsStateError,
    );

    expect(await _output(local.path, ['diff', '--cached', '--binary']), before);
  });

  test('verifier failure leaves HEAD and canonical bytes unchanged', () async {
    final domain = EntityService(
      workspace,
    ).create(kind: EntityKind.domain, title: 'Unsafe');
    final file = CanonicalRepository(
      workspace,
    ).fileFor(EntityKind.domain, domain.id);
    final bytes = file.readAsBytesSync();
    final head = await _output(local.path, ['rev-parse', 'HEAD']);

    await expectLater(
      CanonicalSyncService(workspace).syncCanonical(
        message: 'must fail',
        verifier: _RecordingVerifier(failAt: 1),
      ),
      throwsStateError,
    );

    expect(await _output(local.path, ['rev-parse', 'HEAD']), head);
    expect(file.readAsBytesSync(), bytes);
    expect(await _output(local.path, ['diff', '--cached', '--quiet']), isEmpty);
  });

  test('rebases non-overlapping remote change and pushes exact HEAD', () async {
    final peer = Directory(p.join(temporary.path, 'peer'));
    await _git(temporary.path, ['clone', remote.path, peer.path]);
    await _identity(peer.path);
    final peerWorkspace = Workspace(peer)..ensureLayout();
    EntityService(
      peerWorkspace,
    ).create(kind: EntityKind.domain, title: 'Remote');
    await _git(peer.path, ['add', 'workdb']);
    await _git(peer.path, ['commit', '-m', 'remote']);
    await _git(peer.path, ['push']);
    EntityService(workspace).create(kind: EntityKind.domain, title: 'Local');

    final report = await CanonicalSyncService(
      workspace,
    ).syncCanonical(message: 'local', verifier: _RecordingVerifier());

    expect(report.rebased, isTrue);
    expect(
      await _output(remote.path, ['rev-parse', 'refs/heads/$branch']),
      report.afterHead,
    );
    expect(
      CanonicalRepository(workspace).list(EntityKind.domain),
      hasLength(3),
    );
  });

  test(
    'rebase conflict restores original HEAD, bytes and clean index',
    () async {
      final domain = CanonicalRepository(
        workspace,
      ).list(EntityKind.domain).single;
      final localFile = CanonicalRepository(
        workspace,
      ).fileFor(EntityKind.domain, domain.id);
      final peer = Directory(p.join(temporary.path, 'peer'));
      await _git(temporary.path, ['clone', remote.path, peer.path]);
      await _identity(peer.path);
      final peerWorkspace = Workspace(peer)..ensureLayout();
      EntityService(peerWorkspace).update(domain, title: 'Remote title');
      await _git(peer.path, ['add', 'workdb']);
      await _git(peer.path, ['commit', '-m', 'remote']);
      await _git(peer.path, ['push']);
      EntityService(workspace).update(domain, title: 'Local title');
      final beforeHead = await _output(local.path, ['rev-parse', 'HEAD']);
      final beforeBytes = localFile.readAsBytesSync();

      await expectLater(
        CanonicalSyncService(workspace).syncCanonical(
          message: 'local conflict',
          verifier: _RecordingVerifier(),
        ),
        throwsStateError,
      );

      expect(await _output(local.path, ['rev-parse', 'HEAD']), beforeHead);
      expect(localFile.readAsBytesSync(), beforeBytes);
      expect(
        await _output(local.path, ['diff', '--cached', '--quiet']),
        isEmpty,
      );
      expect(
        await _output(local.path, ['status', '--porcelain']),
        contains('workdb/'),
      );
    },
  );

  test('rejects a concurrent sync while the workspace lock is held', () async {
    EntityService(workspace).create(kind: EntityKind.domain, title: 'Local');
    final verifier = _BlockingVerifier();
    final first = CanonicalSyncService(
      workspace,
    ).syncCanonical(message: 'first', verifier: verifier);
    await verifier.entered.future;

    await expectLater(
      CanonicalSyncService(
        workspace,
      ).syncCanonical(message: 'second', verifier: _RecordingVerifier()),
      throwsStateError,
    );

    verifier.release.complete();
    await first;
    expect(
      File(p.join(workspace.local.path, 'canonical-sync.lock')).existsSync(),
      isTrue,
    );
  });

  test(
    'claim ref lease and canonical branch push are one atomic transaction',
    () async {
      const claimRef = 'refs/under-claw-work/claims/TSK-fenced';
      final originalClaim = await _output(local.path, ['rev-parse', 'HEAD']);
      await _git(remote.path, ['update-ref', claimRef, originalClaim]);
      EntityService(
        workspace,
      ).create(kind: EntityKind.domain, title: 'Fenced publish succeeds');
      final accepted = await CanonicalSyncService(workspace).syncCanonical(
        message: 'current claim permits branch',
        verifier: _RecordingVerifier(),
        remoteRefLeases: {claimRef: originalClaim},
      );
      expect(accepted.pushed, isTrue);

      final peer = Directory(p.join(temporary.path, 'claim-peer'));
      await _git(temporary.path, ['clone', remote.path, peer.path]);
      await _identity(peer.path);
      await _git(peer.path, ['commit', '--allow-empty', '-m', 'take claim']);
      final replacementClaim = await _output(peer.path, ['rev-parse', 'HEAD']);
      await _git(peer.path, ['push', 'origin', 'HEAD:$claimRef']);
      final branchBefore = await _output(remote.path, [
        'rev-parse',
        'refs/heads/$branch',
      ]);
      EntityService(
        workspace,
      ).create(kind: EntityKind.domain, title: 'Must not publish');

      await expectLater(
        CanonicalSyncService(workspace).syncCanonical(
          message: 'stale claim must fence branch',
          verifier: _RecordingVerifier(),
          remoteRefLeases: {claimRef: originalClaim},
        ),
        throwsStateError,
      );

      expect(
        await _output(remote.path, ['rev-parse', 'refs/heads/$branch']),
        branchBefore,
      );
      expect(
        await _output(remote.path, ['rev-parse', claimRef]),
        replacementClaim,
      );
    },
  );

  test('pushes to configured non-origin remote and remote branch', () async {
    await _git(local.path, ['remote', 'rename', 'origin', 'backup']);
    await _git(local.path, [
      'push',
      'backup',
      'HEAD:refs/heads/canonical-release',
    ]);
    await _git(local.path, [
      'branch',
      '--set-upstream-to=backup/canonical-release',
      branch,
    ]);
    EntityService(workspace).create(kind: EntityKind.domain, title: 'Local');

    final report = await CanonicalSyncService(workspace).syncCanonical(
      message: 'configured target',
      verifier: _RecordingVerifier(),
    );

    expect(
      await _output(remote.path, ['rev-parse', 'refs/heads/canonical-release']),
      report.afterHead,
    );
  });
}

class _MutatingSecondVerifier implements CanonicalPrePushVerifier {
  _MutatingSecondVerifier(this.file);

  final File file;
  var calls = 0;

  @override
  Future<void> verify(Workspace workspace) async {
    calls++;
    if (calls == 2) {
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst('Expected', 'Concurrent'),
        flush: true,
      );
    }
  }
}

class _RecordingVerifier implements CanonicalPrePushVerifier {
  _RecordingVerifier({this.failAt});

  final int? failAt;
  int calls = 0;

  @override
  Future<void> verify(Workspace workspace) async {
    calls++;
    if (calls == failAt) throw StateError('verification failed');
  }
}

class _BlockingVerifier implements CanonicalPrePushVerifier {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> verify(Workspace workspace) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }
}

Future<void> _identity(String directory) async {
  await _git(directory, ['config', 'user.email', 'test@example.invalid']);
  await _git(directory, ['config', 'user.name', 'Canonical Sync Test']);
}

Future<void> _git(String directory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: directory,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      'git',
      arguments,
      result.stderr.toString(),
      result.exitCode,
    );
  }
}

Future<String> _output(String directory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: directory,
    runInShell: false,
  );
  if (result.exitCode != 0 && arguments.last != '--quiet') {
    throw ProcessException(
      'git',
      arguments,
      result.stderr.toString(),
      result.exitCode,
    );
  }
  return result.stdout.toString().trim();
}
