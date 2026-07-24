import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/notion_secret_store.dart';
import 'package:under_claw_work/core/notion_sync_adapter.dart';

class _MemoryBackend implements NotionSecureStorageBackend {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  const ref = NotionSecretRef('os-secure-store://under-claw/notion');

  test('platform store delegates token lifecycle to secure backend', () async {
    final backend = _MemoryBackend();
    final store = PlatformNotionSecretStore(backend: backend);

    await store.writeToken(ref, 'PLACEHOLDER-token');
    expect(await store.readToken(ref), 'PLACEHOLDER-token');
    await store.deleteToken(ref);
    expect(await store.readToken(ref), isNull);
  });

  test('local config is atomic and contains no token', () {
    final root = Directory.systemTemp.createTempSync('notion-config-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/.worklog/notion.json');
    final store = NotionLocalConfigStore(file);
    const config = NotionLocalConfig(
      enabled: true,
      secretRef: ref,
      databases: {'task': 'db-task'},
    );

    store.save(config);
    final text = file.readAsStringSync();
    expect(text, contains(ref.locator));
    expect(text, isNot(contains('PLACEHOLDER-token')));
    expect(store.load()!.databases, {'task': 'db-task'});
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });
}
