import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'environment_service.dart';
import 'id.dart';
import 'schema_validator.dart';
import 'workspace.dart';

/// One registered Agent, bound to the Environment it executes on by ENV id.
class AgentRecord {
  const AgentRecord({
    required this.id,
    required this.name,
    required this.kind,
    required this.environmentId,
    required this.status,
    required this.registeredAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String kind;
  final String environmentId;
  final String status;
  final String registeredAt;
  final String updatedAt;

  AgentRecord copyWith({
    String? name,
    String? kind,
    String? environmentId,
    String? status,
    String? updatedAt,
  }) => AgentRecord(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    environmentId: environmentId ?? this.environmentId,
    status: status ?? this.status,
    registeredAt: registeredAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'id': id,
    'type': 'agent',
    'name': name,
    'kind': kind,
    'environment_id': environmentId,
    'status': status,
    'registered_at': registeredAt,
    'updated_at': updatedAt,
  };

  factory AgentRecord.fromJson(Map<Object?, Object?> raw) {
    final data = raw.map((key, value) => MapEntry(key.toString(), value));
    final registeredAt =
        (data['registered_at'] as String?) ??
        DateTime.now().toUtc().toIso8601String();
    return AgentRecord(
      id: data['id'] as String,
      name: (data['name'] as String?) ?? (data['id'] as String),
      kind: (data['kind'] as String?) ?? 'generic',
      environmentId: (data['environment_id'] as String?) ?? '',
      status: (data['status'] as String?) ?? 'active',
      registeredAt: registeredAt,
      updatedAt: (data['updated_at'] as String?) ?? registeredAt,
    );
  }
}

/// Manages the version-controlled Agent registry
/// (`workdb/config/agents.yaml`). Every Agent references the Environment it
/// runs on by its immutable ENV id, so renaming an environment alias never
/// breaks the binding.
class AgentRegistryService {
  AgentRegistryService(
    this.workspace, {
    this.lockTimeout = _defaultLockTimeout,
    this.staleLockTimeout = _defaultStaleLockTimeout,
  });

  final Workspace workspace;

  /// How long a mutation waits for the registry lock before giving up.
  final Duration lockTimeout;

  /// A lock older than this is treated as abandoned by a crashed writer and is
  /// safely reclaimed.
  final Duration staleLockTimeout;

  static const _defaultLockTimeout = Duration(seconds: 5);
  static const _defaultStaleLockTimeout = Duration(minutes: 5);

  File get _registry => File(p.join(workspace.config.path, 'agents.yaml'));

  File get _lock => File('${_registry.path}.lock');

  List<AgentRecord> list() {
    if (!_registry.existsSync()) return const [];
    final decoded = loadYaml(_registry.readAsStringSync());
    if (decoded is! Map) return const [];
    return ((decoded['agents'] as List?) ?? const [])
        .whereType<Map>()
        .map(AgentRecord.fromJson)
        .toList()
      ..sort((left, right) => left.id.compareTo(right.id));
  }

  AgentRecord? get(String id) =>
      list().where((record) => record.id == id).firstOrNull;

  /// Registers an Agent for [environmentId]. The environment must exist in the
  /// Environment registry, enforcing the Environment ↔ Agent link.
  AgentRecord register({
    required String name,
    required String kind,
    required String environmentId,
  }) {
    if (name.trim().isEmpty) {
      throw const FormatException('Agent name is required.');
    }
    if (EnvironmentService(workspace).get(environmentId) == null) {
      throw StateError('Unknown environment: $environmentId');
    }
    // Read-modify-write under an exclusive lock so two concurrent registrations
    // cannot each read the old list and clobber the other (lost update).
    return _withLock(() {
      final now = DateTime.now().toUtc().toIso8601String();
      final created = AgentRecord(
        id: newId('AGT'),
        name: name.trim(),
        kind: kind.trim().isEmpty ? 'generic' : kind.trim(),
        environmentId: environmentId,
        status: 'active',
        registeredAt: now,
        updatedAt: now,
      );
      _writeLocked([...list(), created]);
      return created;
    });
  }

  AgentRecord bindEnvironment(String id, String environmentId) {
    if (EnvironmentService(workspace).get(environmentId) == null) {
      throw StateError('Unknown environment: $environmentId');
    }
    return _mutate(
      id,
      (record) => record.copyWith(environmentId: environmentId),
    );
  }

  /// Edits only the display name. The immutable id and Environment binding are
  /// untouched, so references to the agent id stay valid.
  AgentRecord rename(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Agent name is required.');
    }
    return _mutate(id, (record) => record.copyWith(name: trimmed));
  }

  /// Edits the runtime kind label (e.g. `hermes`, `claude`, `codex`). This is
  /// the "Mac vs Hermes"-style discriminator and must stay editable; the
  /// immutable id and Environment binding are untouched.
  AgentRecord setKind(String id, String kind) {
    final trimmed = kind.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Agent kind is required.');
    }
    return _mutate(id, (record) => record.copyWith(kind: trimmed));
  }

  static const _allowedStatuses = {'active', 'inactive', 'retired'};

  AgentRecord setStatus(String id, String status) {
    if (!_allowedStatuses.contains(status)) {
      throw FormatException(
        'Agent status must be one of ${_allowedStatuses.join(', ')}.',
      );
    }
    return _mutate(id, (record) => record.copyWith(status: status));
  }

  AgentRecord deactivate(String id) => setStatus(id, 'inactive');
  AgentRecord activate(String id) => setStatus(id, 'active');

  void validateAll() {
    final validator = WorklogContractValidator();
    final environments = EnvironmentService(workspace);
    final ids = <String>{};
    for (final record in list()) {
      if (!ids.add(record.id)) {
        throw ContractViolation(record.id, 'id', 'duplicate agent id');
      }
      validator.validateAgent(record.toJson());
      if (environments.get(record.environmentId) == null) {
        throw ContractViolation(
          record.id,
          'environment_id',
          'references missing environment ${record.environmentId}',
        );
      }
    }
  }

  AgentRecord _mutate(String id, AgentRecord Function(AgentRecord) transform) {
    return _withLock(() {
      final records = list();
      final target = records.where((record) => record.id == id).firstOrNull;
      if (target == null) throw StateError('Agent does not exist: $id');
      final updated = transform(
        target,
      ).copyWith(updatedAt: DateTime.now().toUtc().toIso8601String());
      _writeLocked([
        for (final record in records) record.id == id ? updated : record,
      ]);
      return updated;
    });
  }

  /// Serializes read-modify-write mutations behind an exclusive lock file with
  /// bounded retry and stale-lock reclamation, mirroring [EnvironmentService].
  T _withLock<T>(T Function() action) {
    workspace.config.createSync(recursive: true);
    final deadline = DateTime.now().add(lockTimeout);
    while (true) {
      try {
        _lock.createSync(exclusive: true);
        break;
      } on FileSystemException {
        if (_reclaimStaleLock()) continue;
        if (DateTime.now().isAfter(deadline)) {
          throw StateError(
            'Agent registry is locked (${_lock.path}); another process may be '
            'updating it.',
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
      return false;
    } on FormatException {
      return false;
    }
  }

  /// Atomic durable write held under [_withLock]: temp file then rename.
  void _writeLocked(List<AgentRecord> records) {
    final payload = {
      'schema_version': 1,
      'agents': [for (final record in records) record.toJson()],
    };
    final temporary = File('${_registry.path}.tmp');
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
      flush: true,
    );
    temporary.renameSync(_registry.path);
  }
}
