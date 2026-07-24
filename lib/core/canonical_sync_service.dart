import 'dart:io';

import 'package:path/path.dart' as p;

import 'canonical_repository.dart';
import 'entity_service.dart';
import 'projection.dart';
import 'schema_validator.dart';
import 'task_repository.dart';
import 'workspace.dart';

abstract interface class CanonicalPrePushVerifier {
  Future<void> verify(Workspace workspace);
}

class CanonicalSyncReport {
  const CanonicalSyncReport({
    required this.beforeHead,
    required this.afterHead,
    required this.remoteHead,
    required this.committed,
    required this.rebased,
    required this.pushed,
  });

  final String beforeHead;
  final String afterHead;
  final String remoteHead;
  final bool committed;
  final bool rebased;
  final bool pushed;
}

/// Publishes Git-canonical `workdb` changes through one fail-closed transaction.
///
/// The caller's index must be clean and only canonical worktree files may be
/// dirty. Any failure after the local commit restores the exact pre-sync
/// canonical bytes, original HEAD and clean index.
class CanonicalSyncService {
  CanonicalSyncService(this.workspace);

  static final Set<String> _activeWorkspaceLocks = <String>{};

  final Workspace workspace;

  Future<CanonicalSyncReport> syncCanonical({
    required String message,
    required CanonicalPrePushVerifier verifier,
  }) async {
    workspace.ensureLayout();
    final lock = File(p.join(workspace.local.path, 'canonical-sync.lock'));
    final lockPath = p.normalize(p.absolute(lock.path));
    if (!_activeWorkspaceLocks.add(lockPath)) {
      throw StateError('Canonical sync is already running for this workspace.');
    }
    late final RandomAccessFile handle;
    try {
      handle = lock.openSync(mode: FileMode.append);
    } on FileSystemException {
      _activeWorkspaceLocks.remove(lockPath);
      rethrow;
    }
    try {
      handle.lockSync(FileLock.exclusive);
      handle.setPositionSync(0);
      handle.truncateSync(0);
      handle.writeStringSync(
        'pid=$pid\nstarted_at=${DateTime.now().toUtc().toIso8601String()}\n',
      );
      handle.flushSync();
    } on FileSystemException {
      handle.closeSync();
      _activeWorkspaceLocks.remove(lockPath);
      throw StateError('Canonical sync is already running for this workspace.');
    }
    try {
      return await _syncLocked(message: message, verifier: verifier);
    } finally {
      handle.unlockSync();
      handle.closeSync();
      _activeWorkspaceLocks.remove(lockPath);
      // Keep the pathname and inode stable. Deleting an advisory-lock file
      // permits a third process to lock a new inode while a waiter still holds
      // the original one.
    }
  }

  Future<CanonicalSyncReport> _syncLocked({
    required String message,
    required CanonicalPrePushVerifier verifier,
  }) async {
    if (message.trim().isEmpty) {
      throw const FormatException('Canonical sync commit message is required.');
    }
    final upstream = await _requireRepository();
    await _requireCleanIndex();
    await _requireCanonicalOnlyWorktree();

    final beforeHead = await _output(['rev-parse', 'HEAD']);
    final snapshot = _CanonicalSnapshot.capture(workspace.workdb);
    var committed = false;
    var rebased = false;
    try {
      await _validateAndVerify(verifier);
      await _checked(['add', '--', 'workdb']);
      final staged = await _result([
        'diff',
        '--cached',
        '--quiet',
        '--',
        'workdb',
      ]);
      if (staged.exitCode == 1) {
        await _checked(['commit', '-m', message.trim(), '--', 'workdb']);
        committed = true;
      } else if (staged.exitCode != 0) {
        throw ProcessException('git', const [
          'diff',
          '--cached',
          '--quiet',
          '--',
          'workdb',
        ]);
      }

      await _checked(['fetch', '--prune', upstream.remoteName]);
      final remoteHead = await _output(['rev-parse', upstream.trackingRef]);
      final headBeforeRebase = await _output(['rev-parse', 'HEAD']);
      if (headBeforeRebase != remoteHead) {
        final base = await _output([
          'merge-base',
          'HEAD',
          upstream.trackingRef,
        ]);
        if (base != remoteHead) {
          final rebase = await _result(['rebase', upstream.trackingRef]);
          if (rebase.exitCode != 0) {
            await _result(['rebase', '--abort']);
            throw StateError(
              'CANONICAL_REBASE_CONFLICT: '
              '${rebase.stderr.toString().trim()}',
            );
          }
          rebased = true;
        }
      }

      // Remote non-overlapping changes may alter the graph. Validate the merged
      // canonical tree and scan it again immediately before the exact push.
      await _validateAndVerify(verifier);
      final expectedRemote = await _output(['rev-parse', upstream.trackingRef]);
      final afterHead = await _output(['rev-parse', 'HEAD']);
      final pushed = await _result([
        'push',
        '--force-with-lease=${upstream.remoteRef}:$expectedRemote',
        upstream.remoteName,
        'HEAD:${upstream.remoteRef}',
      ]);
      if (pushed.exitCode != 0) {
        throw StateError(
          'CANONICAL_PUSH_REJECTED: ${pushed.stderr.toString().trim()}',
        );
      }
      return CanonicalSyncReport(
        beforeHead: beforeHead,
        afterHead: afterHead,
        remoteHead: expectedRemote,
        committed: committed,
        rebased: rebased,
        pushed: true,
      );
    } on Object {
      await _restore(beforeHead, snapshot);
      rethrow;
    }
  }

  Future<void> _validateAndVerify(CanonicalPrePushVerifier verifier) async {
    EntityService(workspace).validateGraph();
    WorklogContractValidator().validateRepository(
      CanonicalRepository(workspace),
      TaskRepository(workspace).list(),
    );
    final projection = ProjectionStore(workspace);
    try {
      projection.rebuild();
    } finally {
      projection.dispose();
    }
    await verifier.verify(workspace);
  }

  Future<_GitUpstream> _requireRepository() async {
    final result = await _result(['rev-parse', '--is-inside-work-tree']);
    if (result.exitCode != 0 ||
        result.stdout.toString().trim().toLowerCase() != 'true') {
      throw StateError('Canonical sync requires a Git worktree.');
    }
    final localBranch = await _output(['symbolic-ref', '--short', 'HEAD']);
    final tracking = await _result([
      'rev-parse',
      '--symbolic-full-name',
      '@{upstream}',
    ]);
    if (tracking.exitCode != 0) {
      throw StateError('Canonical sync requires a configured upstream.');
    }
    final descriptor = await _result([
      'for-each-ref',
      '--format=%(upstream:remotename)%09%(upstream:remoteref)',
      'refs/heads/$localBranch',
    ]);
    if (descriptor.exitCode != 0) {
      throw StateError(
        'Canonical sync cannot resolve its configured upstream.',
      );
    }
    final parts = descriptor.stdout.toString().trim().split('\t');
    final trackingRef = tracking.stdout.toString().trim();
    if (parts.length != 2 ||
        parts[0].isEmpty ||
        !parts[1].startsWith('refs/heads/') ||
        !trackingRef.startsWith('refs/remotes/')) {
      throw StateError('Canonical sync requires a branch upstream.');
    }
    return _GitUpstream(parts[0], parts[1], trackingRef);
  }

  Future<void> _requireCleanIndex() async {
    final staged = await _result(['diff', '--cached', '--quiet']);
    if (staged.exitCode == 1) {
      throw StateError(
        'Canonical sync refuses to modify a non-empty Git index.',
      );
    }
    if (staged.exitCode != 0) {
      throw ProcessException('git', const ['diff', '--cached', '--quiet']);
    }
  }

  Future<void> _requireCanonicalOnlyWorktree() async {
    final status = await _output(['status', '--porcelain=v1', '-z']);
    for (final entry
        in status.split('\u0000').where((value) => value.isNotEmpty)) {
      // Porcelain v1 is `XY path`; rename/copy records contain a second NUL
      // path, which is rejected because it cannot be proven canonical here.
      if (entry.length < 4) {
        throw StateError('Unrecognized Git status entry.');
      }
      final path = entry.substring(3);
      if (p.isAbsolute(path) ||
          (path != 'workdb' && !p.isWithin('workdb', path))) {
        throw StateError('Canonical sync refuses non-workdb change: $path');
      }
    }
  }

  Future<void> _restore(String beforeHead, _CanonicalSnapshot snapshot) async {
    await _result(['rebase', '--abort']);
    await _checked(['reset', '--mixed', beforeHead]);
    snapshot.restore();
  }

  Future<String> _output(List<String> arguments) async {
    final result = await _checked(arguments);
    return result.stdout.toString().trim();
  }

  Future<ProcessResult> _checked(List<String> arguments) async {
    final result = await _result(arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        arguments,
        result.stderr.toString().trim(),
        result.exitCode,
      );
    }
    return result;
  }

  Future<ProcessResult> _result(List<String> arguments) => Process.run(
    'git',
    arguments,
    workingDirectory: workspace.root.path,
    runInShell: false,
  );
}

class _CanonicalSnapshot {
  _CanonicalSnapshot(this.root, this.files);

  factory _CanonicalSnapshot.capture(Directory root) {
    final files = <String, List<int>>{};
    if (root.existsSync()) {
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        files[p.relative(file.path, from: root.path)] = file.readAsBytesSync();
      }
    }
    return _CanonicalSnapshot(root, files);
  }

  final Directory root;
  final Map<String, List<int>> files;

  void restore() {
    if (root.existsSync()) {
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        final relative = p.relative(file.path, from: root.path);
        if (!files.containsKey(relative)) file.deleteSync();
      }
    }
    for (final entry in files.entries) {
      final file = File(p.join(root.path, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(entry.value, flush: true);
    }
  }
}

class _GitUpstream {
  const _GitUpstream(this.remoteName, this.remoteRef, this.trackingRef);

  final String remoteName;
  final String remoteRef;
  final String trackingRef;
}
