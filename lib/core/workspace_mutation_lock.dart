import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'workspace.dart';

/// Serializes canonical mutations and sync/rollback across isolates and
/// processes. Nested calls are reentrant only while their owning scope is live.
class WorkspaceMutationLock {
  WorkspaceMutationLock._();

  static final Object _zoneKey = Object();
  static final Set<String> _activePaths = <String>{};

  static Future<T> runExclusive<T>(
    Workspace workspace,
    Future<T> Function() action,
  ) async {
    workspace.ensureLayout();
    final path = _path(workspace);
    final inherited = Zone.current[_zoneKey];
    if (inherited is _MutationLockOwner &&
        inherited.active &&
        inherited.path == path) {
      return action();
    }
    if (!_activePaths.add(path)) {
      throw StateError('Canonical mutation is already in progress.');
    }
    final owner = _MutationLockOwner(path);
    RandomAccessFile? handle;
    var locked = false;
    try {
      handle = File(path).openSync(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      locked = true;
      return await runZoned(
        action,
        zoneValues: <Object, Object>{_zoneKey: owner},
      );
    } finally {
      owner.active = false;
      try {
        if (locked) await handle!.unlock();
      } finally {
        try {
          await handle?.close();
        } finally {
          _activePaths.remove(path);
        }
      }
    }
  }

  static T runExclusiveSync<T>(Workspace workspace, T Function() action) {
    workspace.ensureLayout();
    final path = _path(workspace);
    final inherited = Zone.current[_zoneKey];
    if (inherited is _MutationLockOwner &&
        inherited.active &&
        inherited.path == path) {
      return action();
    }
    if (!_activePaths.add(path)) {
      throw StateError('Canonical mutation is already in progress.');
    }
    final owner = _MutationLockOwner(path);
    RandomAccessFile? handle;
    var locked = false;
    try {
      handle = File(path).openSync(mode: FileMode.append);
      handle.lockSync(FileLock.exclusive);
      locked = true;
      return runZoned(action, zoneValues: <Object, Object>{_zoneKey: owner});
    } finally {
      owner.active = false;
      try {
        if (locked) handle!.unlockSync();
      } finally {
        try {
          handle?.closeSync();
        } finally {
          _activePaths.remove(path);
        }
      }
    }
  }

  static String _path(Workspace workspace) => p.normalize(
    p.absolute(p.join(workspace.local.path, 'canonical-mutation.lock')),
  );
}

class _MutationLockOwner {
  _MutationLockOwner(this.path);

  final String path;
  bool active = true;
}
