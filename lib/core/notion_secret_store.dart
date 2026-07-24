import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'notion_sync_adapter.dart';

abstract interface class NotionSecureStorageBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterNotionSecureStorageBackend implements NotionSecureStorageBackend {
  const FlutterNotionSecureStorageBackend([
    this.storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage storage;

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

/// OS-backed credential storage. Only the opaque locator is persisted in local
/// config; the token never leaves the platform secure store.
class PlatformNotionSecretStore implements NotionSecretStore {
  const PlatformNotionSecretStore({
    NotionSecureStorageBackend backend =
        const FlutterNotionSecureStorageBackend(),
  }) : _backend = backend;

  final NotionSecureStorageBackend _backend;

  @override
  Future<String?> readToken(NotionSecretRef ref) => _backend.read(_key(ref));

  @override
  Future<void> writeToken(NotionSecretRef ref, String token) async {
    final value = token.trim();
    if (value.isEmpty) {
      throw const NotionSyncException('Notion token must not be empty.');
    }
    await _backend.write(_key(ref), value);
  }

  @override
  Future<void> deleteToken(NotionSecretRef ref) => _backend.delete(_key(ref));

  String _key(NotionSecretRef ref) {
    final locator = ref.locator.trim();
    if (!locator.startsWith('os-secure-store://') || locator.length <= 18) {
      throw const NotionSyncException('Invalid Notion secret locator.');
    }
    return locator.substring('os-secure-store://'.length);
  }
}

/// Non-secret, installation-local Notion settings.
class NotionLocalConfig {
  const NotionLocalConfig({
    required this.enabled,
    required this.secretRef,
    required this.databases,
  });

  final bool enabled;
  final NotionSecretRef secretRef;
  final Map<String, String> databases;

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'enabled': enabled,
    'secret_ref': secretRef.locator,
    'databases': databases,
  };

  factory NotionLocalConfig.fromJson(Map<Object?, Object?> raw) {
    final locator = raw['secret_ref'];
    final databaseData = raw['databases'];
    if (locator is! String || !locator.startsWith('os-secure-store://')) {
      throw const NotionSyncException('Invalid Notion secret reference.');
    }
    if (databaseData is! Map) {
      throw const NotionSyncException('Notion database mapping is required.');
    }
    final databases = <String, String>{};
    for (final entry in databaseData.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          (entry.value as String).trim().isEmpty) {
        throw const NotionSyncException('Invalid Notion database mapping.');
      }
      databases[entry.key as String] = (entry.value as String).trim();
    }
    return NotionLocalConfig(
      enabled: raw['enabled'] == true,
      secretRef: NotionSecretRef(locator),
      databases: databases,
    );
  }
}

/// Atomic local config persistence. The caller must place this under
/// `.worklog/`; this store rejects canonical `workdb/` paths defensively.
class NotionLocalConfigStore {
  const NotionLocalConfigStore(this.file);

  final File file;

  NotionLocalConfig? load() {
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        throw const NotionSyncException('Invalid Notion local config.');
      }
      return NotionLocalConfig.fromJson(decoded.cast<Object?, Object?>());
    } on FormatException {
      throw const NotionSyncException('Invalid Notion local config JSON.');
    }
  }

  void save(NotionLocalConfig config) {
    final normalized = file.absolute.path.replaceAll('\\', '/');
    if (normalized.contains('/workdb/')) {
      throw const NotionSyncException(
        'Notion local config must not be stored in Git canonical.',
      );
    }
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(config.toJson())}\n',
      flush: true,
    );
    temporary.renameSync(file.path);
  }
}
