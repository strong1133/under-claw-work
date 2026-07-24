import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/canonical_repository.dart';
import 'package:under_claw_work/core/entity_service.dart';
import 'package:under_claw_work/core/environment_service.dart';
import 'package:under_claw_work/core/notion_secret_store.dart';
import 'package:under_claw_work/core/match_service.dart';
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
      final conflict = coordinator.conflict(domain.id)!;
      expect(conflict.gitProperties['title'], 'Git title');
      expect(conflict.notionProperties['title'], 'Notion title');
      await coordinator.resolveKeepGit(domain.id);

      final resolved = await client.pageByCanonicalId(token, domain.id);
      expect(resolved!.properties['title'], 'Git title');
      expect(coordinator.conflict(domain.id), isNull);
    },
  );

  test(
    'Apply Notion commits one inspected conflict without moving cursor',
    () async {
      final domain = EntityService(
        workspace,
      ).create(kind: EntityKind.domain, title: 'Git title');
      var commits = 0;
      final coordinator = NotionSyncCoordinator(
        workspace: workspace,
        client: client,
        secretStore: secrets,
        configStore: configStore,
        commitCanonical: () async => 'commit-${++commits}',
      );
      addTearDown(coordinator.dispose);
      await coordinator.pushCanonical();
      final page = (await client.pageByCanonicalId(token, domain.id))!;
      client.simulateRemoteEdit(page.pageId, {'title': 'Notion title'});
      await expectLater(
        coordinator.pushCanonical(),
        throwsA(isA<NotionConflict>()),
      );
      final stateFile = File('${workspace.local.path}/notion-sync.json');
      final before = stateFile.readAsStringSync();

      final head = await coordinator.resolveApplyNotion(domain.id);

      expect(head, 'commit-1');
      expect(
        CanonicalRepository(
          workspace,
        ).get(EntityKind.domain, domain.id)!.data['title'],
        'Notion title',
      );
      expect(coordinator.conflict(domain.id), isNull);
      expect(stateFile.readAsStringSync(), isNot(before));
    },
  );

  test(
    'Apply Notion commit failure keeps binding and conflict retry-safe',
    () async {
      final domain = EntityService(
        workspace,
      ).create(kind: EntityKind.domain, title: 'Git title');
      var attempts = 0;
      final coordinator = NotionSyncCoordinator(
        workspace: workspace,
        client: client,
        secretStore: secrets,
        configStore: configStore,
        commitCanonical: () async {
          attempts++;
          if (attempts == 1) throw StateError('commit failed');
          return 'commit-ok';
        },
      );
      addTearDown(coordinator.dispose);
      await coordinator.pushCanonical();
      final page = (await client.pageByCanonicalId(token, domain.id))!;
      client.simulateRemoteEdit(page.pageId, {'title': 'Notion title'});
      await expectLater(
        coordinator.pushCanonical(),
        throwsA(isA<NotionConflict>()),
      );
      final stateFile = File('${workspace.local.path}/notion-sync.json');
      final before = stateFile.readAsStringSync();
      final canonicalFile = CanonicalRepository(
        workspace,
      ).fileFor(EntityKind.domain, domain.id);
      final canonicalBefore = canonicalFile.readAsBytesSync();
      final stateBefore = jsonDecode(before) as Map<String, Object?>;

      await expectLater(
        coordinator.resolveApplyNotion(domain.id),
        throwsStateError,
      );
      expect(stateFile.readAsStringSync(), before);
      expect(canonicalFile.readAsBytesSync(), canonicalBefore);
      expect(
        CanonicalRepository(
          workspace,
        ).get(EntityKind.domain, domain.id)!.data['title'],
        'Git title',
      );
      final stateAfter =
          jsonDecode(stateFile.readAsStringSync()) as Map<String, Object?>;
      expect(stateAfter['pull_cursor'], stateBefore['pull_cursor']);
      expect(stateAfter['base_revision'], stateBefore['base_revision']);
      expect(coordinator.conflict(domain.id), isNotNull);

      expect(await coordinator.resolveApplyNotion(domain.id), 'commit-ok');
      expect(coordinator.conflict(domain.id), isNull);
    },
  );

  test('Apply Notion refuses a stale reviewed remote revision', () async {
    final domain = EntityService(
      workspace,
    ).create(kind: EntityKind.domain, title: 'Git title');
    final coordinator = NotionSyncCoordinator(
      workspace: workspace,
      client: client,
      secretStore: secrets,
      configStore: configStore,
      commitCanonical: () async => 'must-not-commit',
    );
    addTearDown(coordinator.dispose);
    await coordinator.pushCanonical();
    final page = (await client.pageByCanonicalId(token, domain.id))!;
    client.simulateRemoteEdit(page.pageId, {'title': 'Reviewed'});
    await expectLater(
      coordinator.pushCanonical(),
      throwsA(isA<NotionConflict>()),
    );
    client.simulateRemoteEdit(page.pageId, {'title': 'Newer'});
    final canonicalFile = CanonicalRepository(
      workspace,
    ).fileFor(EntityKind.domain, domain.id);
    final before = canonicalFile.readAsBytesSync();

    await expectLater(
      coordinator.resolveApplyNotion(domain.id),
      throwsA(isA<NotionConflict>()),
    );

    expect(canonicalFile.readAsBytesSync(), before);
    expect(coordinator.conflict(domain.id), isNotNull);
  });

  test(
    'Apply failure restores the shared environment registry bytes',
    () async {
      const environmentConfig = NotionLocalConfig(
        enabled: true,
        secretRef: ref,
        databases: {'environment': 'db-environment'},
      );
      configStore.save(environmentConfig);
      final environment = EnvironmentService(workspace).register(
        identity: const EnvironmentIdentity(
          machineKey: 'MK-rollback',
          os: 'macos',
          architecture: 'arm64',
        ),
        alias: 'Git Mac',
      );
      final coordinator = NotionSyncCoordinator(
        workspace: workspace,
        client: client,
        secretStore: secrets,
        configStore: configStore,
        commitCanonical: () async => throw StateError('commit failed'),
      );
      addTearDown(coordinator.dispose);
      await coordinator.pushCanonical();
      final page = (await client.pageByCanonicalId(token, environment.id))!;
      client.simulateRemoteEdit(page.pageId, {
        ...page.properties,
        'title': 'Notion Mac',
      });
      await expectLater(
        coordinator.pushCanonical(),
        throwsA(isA<NotionConflict>()),
      );
      final registry = File('${workspace.config.path}/environments.yaml');
      final before = registry.readAsBytesSync();

      await expectLater(
        coordinator.resolveApplyNotion(environment.id),
        throwsStateError,
      );

      expect(registry.readAsBytesSync(), before);
      expect(
        EnvironmentService(workspace).get(environment.id)!.alias,
        'Git Mac',
      );
      expect(coordinator.conflict(environment.id), isNotNull);
    },
  );

  test('inbound Match review_state edit surfaces as a reviewable conflict, '
      'never a blind overwrite', () async {
    const matchConfig = NotionLocalConfig(
      enabled: true,
      secretRef: ref,
      databases: {'match': 'db-match'},
    );
    configStore.save(matchConfig);
    final entities = EntityService(workspace);
    final domain = entities.create(kind: EntityKind.domain, title: 'Product');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'MVP',
      domainId: domain.id,
    );
    final knowledge = entities.create(
      kind: EntityKind.knowledge,
      title: 'Fact',
      domainId: domain.id,
      milestoneId: milestone.id,
    );
    final match = MatchService(workspace).propose(
      subjectId: knowledge.id,
      targetId: milestone.id,
      actorType: 'user',
      actorId: 'user:jsj',
    );
    var commits = 0;
    final coordinator = NotionSyncCoordinator(
      workspace: workspace,
      client: client,
      secretStore: secrets,
      configStore: configStore,
      commitCanonical: () async => 'commit-${++commits}',
    );
    addTearDown(coordinator.dispose);

    await coordinator.pushCanonical();
    final page = (await client.pageByCanonicalId(token, match.id))!;
    // A human flips the review state directly in Notion.
    client.simulateRemoteEdit(page.pageId, {
      ...page.properties,
      'review_state': 'approved',
    });

    // The inbound edit is a reviewable conflict, not a silent overwrite.
    await expectLater(
      coordinator.pullAndCommit(),
      throwsA(isA<NotionReconcileConflict>()),
    );
    expect(commits, 0, reason: 'no Git write on a refused authoritative edit');
    final conflict = coordinator.conflict(match.id)!;
    expect(conflict.type, 'match');
    expect(conflict.gitProperties['review_state'], 'proposed');
    expect(conflict.notionProperties['review_state'], 'approved');
    // Git canonical review state was NOT overwritten.
    expect(MatchService(workspace).get(match.id)!.reviewState, 'proposed');

    // Keep Git re-mirrors the authoritative value back onto the Notion page.
    await coordinator.resolveKeepGit(match.id);
    final resolved = (await client.pageByCanonicalId(token, match.id))!;
    expect(resolved.properties['review_state'], 'proposed');
    expect(coordinator.conflict(match.id), isNull);
  });
}
