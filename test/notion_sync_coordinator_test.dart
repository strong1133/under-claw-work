import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/canonical_repository.dart';
import 'package:under_claw_work/core/entity_service.dart';
import 'package:under_claw_work/core/notion_secret_store.dart';
import 'package:under_claw_work/core/notion_sync_adapter.dart';
import 'package:under_claw_work/core/notion_sync_coordinator.dart';
import 'package:under_claw_work/core/workspace.dart';

void main() {
  const token = 'PLACEHOLDER-coordinator-token';
  const ref = NotionSecretRef('os-secure-store://under-claw/notion');
  const config = NotionLocalConfig(
    enabled: true,
    secretRef: ref,
    databases: {'domain': 'db-domain'},
  );

  late Directory root;
  late Workspace workspace;
  late FakeNotionClient client;
  late FakeNotionSecretStore secrets;
  late NotionLocalConfigStore configStore;

  setUp(() {
    root = Directory.systemTemp.createTempSync('notion-coordinator-');
    workspace = Workspace(root)..ensureLayout();
    client = FakeNotionClient(token);
    secrets = FakeNotionSecretStore(token);
    configStore = NotionLocalConfigStore(
      File('${workspace.local.path}/notion.json'),
    )..save(config);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('explicit push mirrors canonical state', () async {
    final domain = EntityService(
      workspace,
    ).create(kind: EntityKind.domain, title: 'Product');
    final coordinator = NotionSyncCoordinator(
      workspace: workspace,
      client: client,
      secretStore: secrets,
      configStore: configStore,
      commitCanonical: () async => 'unused',
    );
    addTearDown(coordinator.dispose);

    final report = await coordinator.pushCanonical();
    expect(report.pushed, 1);
    final page = await client.pageByCanonicalId(token, domain.id);
    expect(page, isNotNull);
    expect(page!.properties['title'], 'Product');
  });

  test('commit failure leaves inbound edit unacknowledged', () async {
    final domain = EntityService(
      workspace,
    ).create(kind: EntityKind.domain, title: 'Product');
    final coordinator = NotionSyncCoordinator(
      workspace: workspace,
      client: client,
      secretStore: secrets,
      configStore: configStore,
      commitCanonical: () async => throw StateError('commit failed'),
    );
    addTearDown(coordinator.dispose);
    await coordinator.pushCanonical();
    final page = (await client.pageByCanonicalId(token, domain.id))!;
    client.simulateRemoteEdit(page.pageId, {'title': 'Remote'});

    await expectLater(coordinator.pullAndCommit(), throwsStateError);
    await expectLater(coordinator.pullAndCommit(), throwsStateError);
  });

  test(
    'reviewed Keep Git overwrites the conflicting remote revision',
    () async {
      final domain = EntityService(
        workspace,
      ).create(kind: EntityKind.domain, title: 'Git title');
      final coordinator = NotionSyncCoordinator(
        workspace: workspace,
        client: client,
        secretStore: secrets,
        configStore: configStore,
        commitCanonical: () async => 'unused',
      );
      addTearDown(coordinator.dispose);
      await coordinator.pushCanonical();
      final page = (await client.pageByCanonicalId(token, domain.id))!;
      client.simulateRemoteEdit(page.pageId, {'title': 'Notion title'});

      await expectLater(
        coordinator.pushCanonical(),
        throwsA(isA<NotionConflict>()),
      );
      await coordinator.resolveKeepGit(domain.id);

      final resolved = await client.pageByCanonicalId(token, domain.id);
      expect(resolved!.properties['title'], 'Git title');
    },
  );
}
