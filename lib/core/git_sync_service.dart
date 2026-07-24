import 'dart:io';

import 'workspace.dart';

enum GitSyncState { clean, dirty, ahead, behind, diverged, offline, noRemote }

class GitSyncStatus {
  const GitSyncStatus({
    required this.state,
    required this.head,
    this.detail = '',
  });

  final GitSyncState state;
  final String head;
  final String detail;
}

class GitSyncService {
  GitSyncService(this.workspace);

  final Workspace workspace;

  Future<GitSyncStatus> status({bool fetch = true}) async {
    final head = (await _run([
      'rev-parse',
      'HEAD',
    ], allowFailure: true)).stdout.toString().trim();
    final remote = await _run([
      'remote',
      'get-url',
      'origin',
    ], allowFailure: true);
    if (remote.exitCode != 0) {
      return GitSyncStatus(state: GitSyncState.noRemote, head: head);
    }
    if (fetch) {
      final fetched = await _run(['fetch', '--prune'], allowFailure: true);
      if (fetched.exitCode != 0) {
        return GitSyncStatus(
          state: GitSyncState.offline,
          head: head,
          detail: fetched.stderr.toString().trim(),
        );
      }
    }
    final dirty = (await _run([
      'status',
      '--porcelain',
    ])).stdout.toString().trim();
    if (dirty.isNotEmpty) {
      return GitSyncStatus(state: GitSyncState.dirty, head: head);
    }
    final counts = (await _run([
      'rev-list',
      '--left-right',
      '--count',
      'HEAD...@{upstream}',
    ], allowFailure: true)).stdout.toString().trim().split(RegExp(r'\s+'));
    if (counts.length != 2) {
      return GitSyncStatus(state: GitSyncState.clean, head: head);
    }
    final ahead = int.parse(counts[0]);
    final behind = int.parse(counts[1]);
    final state = ahead > 0 && behind > 0
        ? GitSyncState.diverged
        : ahead > 0
        ? GitSyncState.ahead
        : behind > 0
        ? GitSyncState.behind
        : GitSyncState.clean;
    return GitSyncStatus(state: state, head: head);
  }

  Future<void> pullFastForward() async {
    final current = await status();
    if (current.state == GitSyncState.dirty) {
      throw StateError('Refusing to pull over uncommitted canonical changes.');
    }
    if (current.state == GitSyncState.offline) {
      throw StateError('Repository is offline: ${current.detail}');
    }
    if (current.state == GitSyncState.diverged) {
      throw StateError(
        'Repository diverged; explicit conflict resolution required.',
      );
    }
    await _checked(['pull', '--ff-only']);
  }

  /// Worker boundary: fetch and reconcile before inspecting canonical requests.
  Future<void> reconcileForWorker() => pullFastForward();

  /// Publishes only canonical `workdb` changes. A rejected push is surfaced;
  /// workers must not silently merge or continue from stale state.
  Future<String> publishWorkerChanges({required String operationId}) async {
    if (!operationId.startsWith('OPR-')) {
      throw const FormatException('Worker publish requires an OPR- id.');
    }
    final current = await status(fetch: true);
    if (current.state == GitSyncState.behind) {
      await pullFastForward();
    } else if (current.state == GitSyncState.diverged ||
        current.state == GitSyncState.offline) {
      throw StateError('Worker cannot publish from ${current.state.name}.');
    }
    final head = (await status(fetch: false)).head;
    return commitAndPush(
      expectedHead: head,
      message: 'worklog: apply $operationId',
    );
  }

  Future<String> commitAndPush({
    required String expectedHead,
    required String message,
  }) async {
    final actualHead = (await _run([
      'rev-parse',
      'HEAD',
    ], allowFailure: true)).stdout.toString().trim();
    if (actualHead != expectedHead) {
      throw StateError('STALE_HEAD expected=$expectedHead actual=$actualHead');
    }
    await _checked(['add', '--', 'workdb']);
    final staged = await _run([
      'diff',
      '--cached',
      '--quiet',
    ], allowFailure: true);
    if (staged.exitCode == 1) {
      await _checked(['commit', '-m', message]);
    } else if (staged.exitCode != 0) {
      throw ProcessException('git', const ['diff', '--cached', '--quiet']);
    }
    final pushed = await _run(['push'], allowFailure: true);
    if (pushed.exitCode != 0) {
      throw StateError('PUSH_REJECTED: ${pushed.stderr.toString().trim()}');
    }
    return (await _run(['rev-parse', 'HEAD'])).stdout.toString().trim();
  }

  /// Commits the current canonical `workdb` changes to the local repository
  /// (no push) and returns the resulting HEAD commit hash. This is the durable
  /// Git write an inbound-reconcile path binds its acknowledge to: if there is
  /// nothing staged, or `git add`/`git commit` fails (e.g. a broken repo state),
  /// this throws so the caller never acknowledges an edit that was not durably
  /// persisted. Used by the Notion inbound loop, which must not advance its
  /// cursor until the merged edit is committed to Git.
  Future<String> commitCanonical({required String message}) async {
    await _checked(['add', '--', 'workdb']);
    final staged = await _run([
      'diff',
      '--cached',
      '--quiet',
    ], allowFailure: true);
    if (staged.exitCode == 0) {
      throw StateError('NOTHING_TO_COMMIT: no canonical changes to persist.');
    } else if (staged.exitCode != 1) {
      throw ProcessException('git', const ['diff', '--cached', '--quiet']);
    }
    await _checked(['commit', '-m', message]);
    return (await _run(['rev-parse', 'HEAD'])).stdout.toString().trim();
  }

  Future<void> _checked(List<String> arguments) async {
    final result = await _run(arguments, allowFailure: true);
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        arguments,
        result.stderr.toString().trim(),
        result.exitCode,
      );
    }
  }

  Future<ProcessResult> _run(
    List<String> arguments, {
    bool allowFailure = false,
  }) async {
    final result = await Process.run(
      'git',
      arguments,
      workingDirectory: workspace.root.path,
      runInShell: false,
    );
    if (!allowFailure && result.exitCode != 0) {
      throw ProcessException(
        'git',
        arguments,
        result.stderr.toString().trim(),
        result.exitCode,
      );
    }
    return result;
  }
}
