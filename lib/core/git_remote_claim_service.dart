import 'dart:io';

import 'workspace.dart';

class RemoteClaimLease {
  const RemoteClaimLease({
    required this.taskId,
    required this.runId,
    required this.environmentId,
    required this.ref,
    required this.objectId,
    required this.epoch,
    required this.expiresAt,
  });

  final String taskId;
  final String runId;
  final String environmentId;
  final String ref;
  final String objectId;

  /// Monotonic lineage generation. The remote OID remains the authority.
  final int epoch;

  /// Advisory only. It must never authorize acquisition or a canonical write.
  final DateTime expiresAt;
}

abstract interface class RemoteClaimProvider {
  Future<RemoteClaimLease?> tryAcquire({
    required String taskId,
    required String runId,
    required String environmentId,
    required Duration ttl,
    DateTime? now,
  });

  Future<RemoteClaimLease?> renew(
    RemoteClaimLease lease, {
    required Duration ttl,
    DateTime? now,
  });

  Future<bool> release(RemoteClaimLease lease);

  /// True only while [lease.objectId] is the exact remote ref value.
  Future<bool> isCurrent(RemoteClaimLease lease);
}

/// A Git-ref compare-and-set lease. The remote ref is the lock; commit metadata
/// carries the owner and expiry. Every mutation uses the observed remote OID.
class GitRemoteClaimService implements RemoteClaimProvider {
  GitRemoteClaimService(this.workspace, {this.remote = 'origin'});

  final Workspace workspace;
  final String remote;

  @override
  Future<RemoteClaimLease?> tryAcquire({
    required String taskId,
    required String runId,
    required String environmentId,
    Duration ttl = const Duration(minutes: 5),
    DateTime? now,
  }) async {
    _validateId(taskId, 'TSK');
    _validateId(runId, 'RUN');
    _validateId(environmentId, 'ENV');
    final ref = 'refs/under-claw-work/claims/$taskId';
    final observed = await _remoteObject(ref);
    final instant = (now ?? DateTime.now()).toUtc();
    // Client wall clocks are not a lease authority. An existing ref can only be
    // replaced through the explicit takeover API with its exact observed OID.
    if (observed != null) return null;
    final expiresAt = instant.add(ttl);
    final objectId = await _createLeaseCommit(
      taskId: taskId,
      runId: runId,
      environmentId: environmentId,
      expiresAt: expiresAt,
      epoch: 1,
    );
    final leaseExpectation = observed ?? '';
    final push = await _run([
      'push',
      '--porcelain',
      '--force-with-lease=$ref:$leaseExpectation',
      remote,
      '$objectId:$ref',
    ]);
    if (push.exitCode != 0 || await _remoteObject(ref) != objectId) return null;
    return RemoteClaimLease(
      taskId: taskId,
      runId: runId,
      environmentId: environmentId,
      ref: ref,
      objectId: objectId,
      epoch: 1,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<RemoteClaimLease?> renew(
    RemoteClaimLease lease, {
    Duration ttl = const Duration(minutes: 5),
    DateTime? now,
  }) async {
    if (await _remoteObject(lease.ref) != lease.objectId) return null;
    final expiresAt = (now ?? DateTime.now()).toUtc().add(ttl);
    final objectId = await _createLeaseCommit(
      taskId: lease.taskId,
      runId: lease.runId,
      environmentId: lease.environmentId,
      expiresAt: expiresAt,
      epoch: lease.epoch + 1,
      parent: lease.objectId,
    );
    final result = await _run([
      'push',
      '--porcelain',
      '--force-with-lease=${lease.ref}:${lease.objectId}',
      remote,
      '$objectId:${lease.ref}',
    ]);
    if (result.exitCode != 0 || await _remoteObject(lease.ref) != objectId) {
      return null;
    }
    return RemoteClaimLease(
      taskId: lease.taskId,
      runId: lease.runId,
      environmentId: lease.environmentId,
      ref: lease.ref,
      objectId: objectId,
      epoch: lease.epoch + 1,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<bool> release(RemoteClaimLease lease) async {
    if (await _remoteObject(lease.ref) != lease.objectId) return false;
    final result = await _run([
      'push',
      '--porcelain',
      '--force-with-lease=${lease.ref}:${lease.objectId}',
      remote,
      ':${lease.ref}',
    ]);
    return result.exitCode == 0;
  }

  @override
  Future<bool> isCurrent(RemoteClaimLease lease) async =>
      await _remoteObject(lease.ref) == lease.objectId;

  /// Explicit fail-closed recovery. The caller must supply the exact lease it
  /// has independently decided is abandoned; CAS prevents stale takeover.
  Future<RemoteClaimLease?> takeover(
    RemoteClaimLease abandoned, {
    required String runId,
    required String environmentId,
    Duration ttl = const Duration(minutes: 5),
    DateTime? now,
  }) async {
    _validateId(runId, 'RUN');
    _validateId(environmentId, 'ENV');
    if (!await isCurrent(abandoned)) return null;
    await _checked(['fetch', '--quiet', remote, abandoned.objectId]);
    final expiresAt = (now ?? DateTime.now()).toUtc().add(ttl);
    final objectId = await _createLeaseCommit(
      taskId: abandoned.taskId,
      runId: runId,
      environmentId: environmentId,
      expiresAt: expiresAt,
      epoch: abandoned.epoch + 1,
      parent: abandoned.objectId,
    );
    final result = await _run([
      'push',
      '--porcelain',
      '--force-with-lease=${abandoned.ref}:${abandoned.objectId}',
      remote,
      '$objectId:${abandoned.ref}',
    ]);
    if (result.exitCode != 0 ||
        await _remoteObject(abandoned.ref) != objectId) {
      return null;
    }
    return RemoteClaimLease(
      taskId: abandoned.taskId,
      runId: runId,
      environmentId: environmentId,
      ref: abandoned.ref,
      objectId: objectId,
      epoch: abandoned.epoch + 1,
      expiresAt: expiresAt,
    );
  }

  Future<String> _createLeaseCommit({
    required String taskId,
    required String runId,
    required String environmentId,
    required DateTime expiresAt,
    required int epoch,
    String? parent,
  }) async {
    final tree = (await _checked([
      'rev-parse',
      'HEAD^{tree}',
    ])).stdout.toString().trim();
    final commit = await _run(
      [
        'commit-tree',
        tree,
        if (parent != null) ...['-p', parent],
      ],
      stdin:
          'under-claw-work claim\n\n'
          'task=$taskId\nrun=$runId\nenvironment=$environmentId\n'
          'epoch=$epoch\n'
          'expires_at=${expiresAt.toIso8601String()}\n',
    );
    if (commit.exitCode != 0) {
      throw ProcessException(
        'git',
        const ['commit-tree'],
        commit.stderr.toString().trim(),
        commit.exitCode,
      );
    }
    return commit.stdout.toString().trim();
  }

  Future<String?> _remoteObject(String ref) async {
    final result = await _run(['ls-remote', '--refs', remote, ref]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        const ['ls-remote'],
        result.stderr.toString().trim(),
        result.exitCode,
      );
    }
    final output = result.stdout.toString().trim();
    return output.isEmpty ? null : output.split(RegExp(r'\s+')).first;
  }

  void _validateId(String value, String prefix) {
    if (!RegExp('^$prefix-[A-Za-z0-9._-]+\$').hasMatch(value)) {
      throw FormatException('Invalid $prefix identifier.');
    }
  }

  Future<ProcessResult> _checked(List<String> arguments) async {
    final result = await _run(arguments);
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

  Future<ProcessResult> _run(List<String> arguments, {String? stdin}) async {
    final process = await Process.start(
      'git',
      arguments,
      workingDirectory: workspace.root.path,
      runInShell: false,
    );
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final stdout = await process.stdout
        .transform(systemEncoding.decoder)
        .join();
    final stderr = await process.stderr
        .transform(systemEncoding.decoder)
        .join();
    final exitCode = await process.exitCode;
    return ProcessResult(process.pid, exitCode, stdout, stderr);
  }
}
