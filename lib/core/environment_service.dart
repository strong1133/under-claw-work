import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'id.dart';
import 'schema_validator.dart';
import 'workspace.dart';

/// Stable, non-secret identity of the physical host an Agent runs on.
///
/// The machine key is a salted hash so the committed registry never leaks the
/// raw hostname. The salt lives in the private, git-ignored `.worklog/`
/// directory, so every physical machine derives its own stable key.
class EnvironmentIdentity {
  const EnvironmentIdentity({
    required this.machineKey,
    required this.os,
    required this.architecture,
  });

  final String machineKey;
  final String os;
  final String architecture;

  /// Detects (and persists) a stable identity for the current machine.
  ///
  /// The derived [machineKey] is written back into `.worklog/machine.json`
  /// alongside the salt so a later reinstall (see [EnvironmentService.relink])
  /// can prove which physical host it used to be even if only the local link
  /// file survived.
  static EnvironmentIdentity detect(Workspace workspace) {
    workspace.ensureLayout();
    final file = File(p.join(workspace.local.path, 'machine.json'));
    Map<String, Object?> data;
    if (file.existsSync()) {
      final decoded = jsonDecode(file.readAsStringSync());
      data = decoded is Map
          ? Map<String, Object?>.from(decoded)
          : <String, Object?>{};
    } else {
      data = <String, Object?>{};
    }
    var salt = data['salt'];
    var freshSalt = false;
    if (salt is! String || salt.isEmpty) {
      final random = Random.secure();
      salt = List<int>.generate(
        16,
        (_) => random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      freshSalt = true;
    }
    final os = Platform.operatingSystem;
    final architecture = Abi.current().toString();
    final digest = sha256.convert(
      utf8.encode('${Platform.localHostname}|$os|$architecture|$salt'),
    );
    final machineKey = 'MK-${digest.toString().substring(0, 32)}';
    // Persist salt + resolved machine key so identity is recoverable locally.
    final next = <String, Object?>{
      ...data,
      'schema_version': 1,
      'salt': salt,
      'machine_key': machineKey,
      // A regenerated salt means the previous machine key (and therefore the
      // ENV binding) can no longer be derived from this host; flag it so the
      // caller/operator can run an explicit relink instead of silently
      // minting a duplicate environment.
      'salt_regenerated': freshSalt && data.isNotEmpty,
    };
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(next)}\n',
      flush: true,
    );
    return EnvironmentIdentity(
      machineKey: machineKey,
      os: os,
      architecture: architecture,
    );
  }
}

/// One registered execution environment.
///
/// `id` and `machineKey` are immutable identifiers. `alias` is a free-form,
/// user-editable display name and is never used as an identity key, so renaming
/// it can never break Task/Run/Event/Claim/Agent references that point at `id`.
class EnvironmentRecord {
  const EnvironmentRecord({
    required this.id,
    required this.machineKey,
    required this.alias,
    required this.os,
    required this.architecture,
    required this.kind,
    required this.capabilities,
    required this.status,
    required this.registeredAt,
    required this.updatedAt,
    this.previousMachineKeys = const [],
  });

  final String id;
  final String machineKey;
  final String alias;
  final String os;
  final String architecture;
  final String kind;
  final List<String> capabilities;
  final String status;
  final String registeredAt;
  final String updatedAt;

  /// Immutable audit of every machine key this environment has ever answered
  /// to. Populated by legacy promotion and by [EnvironmentService.relink] so a
  /// reinstalled host can adopt its old ENV id without minting a duplicate.
  final List<String> previousMachineKeys;

  bool get isActive => status == 'active';
  bool get isLegacy => machineKey.startsWith('legacy:');

  EnvironmentRecord copyWith({
    String? alias,
    String? kind,
    List<String>? capabilities,
    String? status,
    String? os,
    String? architecture,
    String? machineKey,
    List<String>? previousMachineKeys,
    String? updatedAt,
  }) {
    return EnvironmentRecord(
      id: id,
      machineKey: machineKey ?? this.machineKey,
      alias: alias ?? this.alias,
      os: os ?? this.os,
      architecture: architecture ?? this.architecture,
      kind: kind ?? this.kind,
      capabilities: capabilities ?? this.capabilities,
      status: status ?? this.status,
      registeredAt: registeredAt,
      updatedAt: updatedAt ?? this.updatedAt,
      previousMachineKeys: previousMachineKeys ?? this.previousMachineKeys,
    );
  }

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'id': id,
    'type': 'environment',
    'machine_key': machineKey,
    'alias': alias,
    'os': os,
    'architecture': architecture,
    'kind': kind,
    'capabilities': capabilities,
    'status': status,
    if (previousMachineKeys.isNotEmpty)
      'previous_machine_keys': previousMachineKeys,
    'registered_at': registeredAt,
    'updated_at': updatedAt,
  };

  /// Reads a record, tolerating legacy documents that predate the identity
  /// split (they used `name` as the display and had no `machine_key`).
  factory EnvironmentRecord.fromJson(Map<Object?, Object?> raw) {
    final data = raw.map((key, value) => MapEntry(key.toString(), value));
    final id = data['id'] as String;
    final alias = (data['alias'] as String?) ?? (data['name'] as String?) ?? id;
    final machineKey = (data['machine_key'] as String?) ?? 'legacy:$id';
    final registeredAt =
        (data['registered_at'] as String?) ??
        DateTime.now().toUtc().toIso8601String();
    return EnvironmentRecord(
      id: id,
      machineKey: machineKey,
      alias: alias,
      os: (data['os'] as String?) ?? 'unknown',
      architecture: (data['architecture'] as String?) ?? 'unknown',
      kind: (data['kind'] as String?) ?? 'desktop',
      capabilities:
          (data['capabilities'] as List?)?.whereType<String>().toList() ??
          const <String>[],
      status: (data['status'] as String?) ?? 'active',
      registeredAt: registeredAt,
      updatedAt: (data['updated_at'] as String?) ?? registeredAt,
      previousMachineKeys:
          (data['previous_machine_keys'] as List?)
              ?.whereType<String>()
              .toList() ??
          const <String>[],
    );
  }
}

/// Manages the version-controlled environment registry.
///
/// Registration is idempotent by immutable [EnvironmentRecord.machineKey]; the
/// editable [EnvironmentRecord.alias] is never used to match or de-duplicate.
///
/// The registry is the Git-canonical YAML document
/// `workdb/config/environments.yaml`. A pre-existing `environments.json`
/// (from the initial vertical slice) is still read for backward compatibility
/// but is never written again, so the canonical form is YAML per the
/// "Git 정본은 YAML·Markdown" invariant.
class EnvironmentService {
  EnvironmentService(
    this.workspace, {
    this.lockTimeout = _defaultLockTimeout,
    this.staleLockTimeout = _defaultStaleLockTimeout,
  });

  final Workspace workspace;

  /// How long a mutation waits for the registry lock before giving up.
  final Duration lockTimeout;

  /// A lock older than this is treated as abandoned by a crashed writer and is
  /// safely reclaimed, so a process that died mid-write cannot wedge the
  /// registry forever.
  final Duration staleLockTimeout;

  static const _defaultLockTimeout = Duration(seconds: 5);
  static const _defaultStaleLockTimeout = Duration(minutes: 5);

  static const _allowedKinds = {
    'desktop',
    'server',
    'headless',
    'agent_runtime',
  };
  static const _allowedStatuses = {'active', 'inactive', 'retired'};

  File get _registry =>
      File(p.join(workspace.config.path, 'environments.yaml'));

  File get _legacyRegistry =>
      File(p.join(workspace.config.path, 'environments.json'));

  File get _lock => File('${_registry.path}.lock');

  List<EnvironmentRecord> list() {
    final file = _registry.existsSync()
        ? _registry
        : (_legacyRegistry.existsSync() ? _legacyRegistry : null);
    if (file == null) return const [];
    final decoded = loadYaml(file.readAsStringSync());
    if (decoded is! Map) return const [];
    final environments =
        ((decoded['environments'] as List?) ?? const [])
            .whereType<Map>()
            .map(EnvironmentRecord.fromJson)
            .toList()
          ..sort((left, right) => left.id.compareTo(right.id));
    return environments;
  }

  EnvironmentRecord? get(String id) =>
      list().where((record) => record.id == id).firstOrNull;

  EnvironmentRecord? byMachineKey(String machineKey) =>
      list().where((record) => record.machineKey == machineKey).firstOrNull;

  /// Registers the host as an environment. Idempotent by machine key: an
  /// existing record is returned unchanged (its editable alias is preserved),
  /// while volatile facts (os/architecture) are refreshed.
  ///
  /// If no record answers to [EnvironmentIdentity.machineKey] but a single
  /// legacy (name-only) record shares the requested [alias] on a compatible
  /// OS, that record is safely promoted exactly once — its immutable id is
  /// preserved and no duplicate ENV is created.
  EnvironmentRecord register({
    required EnvironmentIdentity identity,
    required String alias,
    String kind = 'desktop',
    List<String> capabilities = const ['git'],
  }) {
    final trimmedAlias = alias.trim();
    if (trimmedAlias.isEmpty) {
      throw const FormatException('Environment alias is required.');
    }
    _requireKind(kind);
    return _withLock(() {
      final now = DateTime.now().toUtc().toIso8601String();
      final records = list();
      final existing = records
          .where((record) => record.machineKey == identity.machineKey)
          .firstOrNull;
      if (existing != null) {
        final refreshed = existing.copyWith(
          os: identity.os,
          architecture: identity.architecture,
          updatedAt: now,
        );
        _writeLocked([
          for (final record in records)
            record.id == existing.id ? refreshed : record,
        ]);
        return refreshed;
      }
      // One-time safe promotion of a legacy name-only record for this host.
      final promotable = records
          .where(
            (record) =>
                record.isLegacy &&
                record.status == 'active' &&
                record.alias == trimmedAlias &&
                (record.os == identity.os || record.os == 'unknown'),
          )
          .toList();
      if (promotable.length == 1) {
        final legacy = promotable.single;
        final promoted = legacy.copyWith(
          machineKey: identity.machineKey,
          os: identity.os,
          architecture: identity.architecture,
          previousMachineKeys: [
            ...legacy.previousMachineKeys,
            legacy.machineKey,
          ],
          updatedAt: now,
        );
        _writeLocked([
          for (final record in records)
            record.id == legacy.id ? promoted : record,
        ]);
        return promoted;
      }
      final created = EnvironmentRecord(
        id: newId('ENV'),
        machineKey: identity.machineKey,
        alias: trimmedAlias,
        os: identity.os,
        architecture: identity.architecture,
        kind: kind,
        capabilities: capabilities,
        status: 'active',
        registeredAt: now,
        updatedAt: now,
      );
      _writeLocked([...records, created]);
      return created;
    });
  }

  /// Rotates the immutable id's machine key onto a new host identity, keeping
  /// the ENV id (and therefore every reference to it) intact. This is the
  /// recovery path when `.worklog/machine.json` — and therefore the salt — is
  /// lost: the reinstalled host derives a fresh machine key and adopts its old
  /// environment instead of registering a duplicate. The superseded key is
  /// preserved in [EnvironmentRecord.previousMachineKeys] as an immutable
  /// audit trail.
  EnvironmentRecord relink(String id, EnvironmentIdentity identity) {
    return _withLock(() {
      final records = list();
      final target = records.where((record) => record.id == id).firstOrNull;
      if (target == null) {
        throw StateError('Environment does not exist: $id');
      }
      if (records.any(
        (record) => record.id != id && record.machineKey == identity.machineKey,
      )) {
        throw StateError(
          'Machine key ${identity.machineKey} already binds another '
          'environment; refusing to relink.',
        );
      }
      final relinked = target.copyWith(
        machineKey: identity.machineKey,
        os: identity.os,
        architecture: identity.architecture,
        previousMachineKeys: target.machineKey == identity.machineKey
            ? target.previousMachineKeys
            : [...target.previousMachineKeys, target.machineKey],
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      _writeLocked([
        for (final record in records) record.id == id ? relinked : record,
      ]);
      // Refresh the local link file so future detect() calls agree.
      final linkFile = File(p.join(workspace.local.path, 'machine.json'));
      if (linkFile.existsSync()) {
        final decoded = jsonDecode(linkFile.readAsStringSync());
        if (decoded is Map) {
          final next = <String, Object?>{
            ...Map<String, Object?>.from(decoded),
            'environment_id': id,
            'salt_regenerated': false,
          };
          linkFile.writeAsStringSync(
            '${const JsonEncoder.withIndent('  ').convert(next)}\n',
            flush: true,
          );
        }
      }
      return relinked;
    });
  }

  /// Edits only the user-facing alias. The immutable id and machine key are
  /// untouched, so every entity that references the environment id stays valid.
  EnvironmentRecord rename(String id, String alias) {
    final trimmed = alias.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Environment alias is required.');
    }
    return _mutate(id, (record) => record.copyWith(alias: trimmed));
  }

  EnvironmentRecord setKind(String id, String kind) {
    _requireKind(kind);
    return _mutate(id, (record) => record.copyWith(kind: kind));
  }

  EnvironmentRecord setCapabilities(String id, List<String> capabilities) {
    final normalized = <String>{
      for (final capability in capabilities) capability.trim(),
    }.where((capability) => capability.isNotEmpty).toList()..sort();
    return _mutate(id, (record) => record.copyWith(capabilities: normalized));
  }

  EnvironmentRecord setStatus(String id, String status) {
    if (!_allowedStatuses.contains(status)) {
      throw FormatException(
        'Environment status must be one of ${_allowedStatuses.join(', ')}.',
      );
    }
    return _mutate(id, (record) => record.copyWith(status: status));
  }

  EnvironmentRecord deactivate(String id) => setStatus(id, 'inactive');
  EnvironmentRecord activate(String id) => setStatus(id, 'active');

  /// Runtime acceptance boundary for the registry: validates every record
  /// against the environment contract (id/machine_key patterns, required
  /// fields, kind/status enums). Called from the whole-graph validation pass.
  void validateAll() {
    final validator = WorklogContractValidator();
    final ids = <String>{};
    for (final record in list()) {
      if (!ids.add(record.id)) {
        throw ContractViolation(record.id, 'id', 'duplicate environment id');
      }
      validator.validateEnvironment(record.toJson());
    }
  }

  EnvironmentRecord _mutate(
    String id,
    EnvironmentRecord Function(EnvironmentRecord) transform,
  ) {
    return _withLock(() {
      final records = list();
      final target = records.where((record) => record.id == id).firstOrNull;
      if (target == null) {
        throw StateError('Environment does not exist: $id');
      }
      final updated = transform(
        target,
      ).copyWith(updatedAt: DateTime.now().toUtc().toIso8601String());
      _writeLocked([
        for (final record in records) record.id == id ? updated : record,
      ]);
      return updated;
    });
  }

  void _requireKind(String kind) {
    if (!_allowedKinds.contains(kind)) {
      throw FormatException(
        'Environment kind must be one of ${_allowedKinds.join(', ')}.',
      );
    }
  }

  /// Serializes read-modify-write mutations behind an exclusive lock file so
  /// concurrent managers cannot clobber each other (lost update). The lock is
  /// acquired with a bounded retry and always released.
  T _withLock<T>(T Function() action) {
    workspace.config.createSync(recursive: true);
    final deadline = DateTime.now().add(lockTimeout);
    while (true) {
      try {
        _lock.createSync(exclusive: true);
        break;
      } on FileSystemException {
        // A crashed writer can leave its exclusive lock behind. Reclaim it once
        // it is provably older than [staleLockTimeout] instead of blocking
        // forever, then retry acquisition immediately.
        if (_reclaimStaleLock()) continue;
        if (DateTime.now().isAfter(deadline)) {
          throw StateError(
            'Environment registry is locked (${_lock.path}); another '
            'process may be updating it.',
          );
        }
        sleep(const Duration(milliseconds: 25));
      }
    }
    try {
      _lock.writeAsStringSync(
        '{"pid":$pid,"at":"${DateTime.now().toUtc().toIso8601String()}"}',
        flush: true,
      );
      return action();
    } finally {
      if (_lock.existsSync()) _lock.deleteSync();
    }
  }

  /// Removes the lock file only when it carries a machine-readable timestamp
  /// that is older than [staleLockTimeout]. A lock without a parseable
  /// timestamp is left untouched (fail-safe: never steal a lock we cannot
  /// reason about).
  bool _reclaimStaleLock() {
    try {
      final decoded = jsonDecode(_lock.readAsStringSync());
      final at = decoded is Map ? DateTime.tryParse('${decoded['at']}') : null;
      if (at == null) return false;
      if (DateTime.now().toUtc().difference(at.toUtc()) <= staleLockTimeout) {
        return false;
      }
      _lock.deleteSync();
      return true;
    } on FileSystemException {
      // The lock vanished between the failed create and this read; let the
      // caller retry the exclusive create.
      return false;
    } on FormatException {
      return false;
    }
  }

  /// Atomic durable write: encode to a temp file then rename over the target,
  /// so a crashed writer never leaves a half-written registry. Must be called
  /// while holding the lock.
  void _writeLocked(List<EnvironmentRecord> records) {
    final validator = WorklogContractValidator();
    for (final record in records) {
      validator.validateEnvironment(record.toJson());
    }
    final payload = {
      'schema_version': 1,
      'environments': [for (final record in records) record.toJson()],
    };
    final temporary = File('${_registry.path}.tmp');
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
      flush: true,
    );
    temporary.renameSync(_registry.path);
  }
}
