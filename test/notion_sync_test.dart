import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  // A placeholder token that stands in for an OS secure-store secret. It must
  // never surface in the fake's call log, the sync state, or any fixture.
  const token = 'PLACEHOLDER-secret-token-do-not-leak';
  const secretRef = NotionSecretRef('os-secure-store://under-claw-work/notion');
  final databases = const NotionDatabaseMap({
    'domain': 'db_domain',
    'milestone': 'db_milestone',
    'objective': 'db_objective',
    'task': 'db_task',
    'knowledge': 'db_knowledge',
    'reference': 'db_reference',
    'environment': 'db_environment',
    'agent': 'db_agent',
    'match': 'db_match',
  });

  NotionSyncAdapter buildAdapter(FakeNotionClient client) => NotionSyncAdapter(
    client: client,
    secretStore: FakeNotionSecretStore(token),
    secretRef: secretRef,
    databases: databases,
  );

  group('Notion sync adapter contract (requirement 5)', () {
    test(
      'push is idempotent by canonical id and maps id <-> page id',
      () async {
        final client = FakeNotionClient(token);
        final adapter = buildAdapter(client);

        final created = await adapter.push(
          const NotionSyncEntity(
            canonicalId: 'TSK-1',
            type: 'task',
            properties: {'title': 'First'},
          ),
        );
        expect(created.created, isTrue);
        expect(adapter.state.canonicalToPage['TSK-1'], created.pageId);
        expect(adapter.state.pageToCanonical[created.pageId], 'TSK-1');

        // Re-pushing the same canonical id updates rather than duplicating.
        final updated = await adapter.push(
          const NotionSyncEntity(
            canonicalId: 'TSK-1',
            type: 'task',
            properties: {'title': 'Second'},
          ),
        );
        expect(updated.created, isFalse);
        expect(updated.pageId, created.pageId);
        expect(
          (await client.page(token, created.pageId))!.properties['title'],
          'Second',
        );
      },
    );

    test('credential/token is never exposed in logs, state or pages', () async {
      final client = FakeNotionClient(token);
      final adapter = buildAdapter(client);
      await adapter.push(
        const NotionSyncEntity(
          canonicalId: 'DOM-1',
          type: 'domain',
          properties: {'title': 'Domain'},
        ),
      );
      final page = (await client.page(
        token,
        adapter.state.canonicalToPage['DOM-1']!,
      ))!;
      expect(client.callLog.join('\n'), isNot(contains(token)));
      expect(adapter.state.canonicalToPage.toString(), isNot(contains(token)));
      expect(adapter.state.baseRevision.toString(), isNot(contains(token)));
      expect(page.properties.toString(), isNot(contains(token)));
      expect(page.origin, isNot(contains(token)));
    });

    test(
      'origin marker breaks the echo loop and pull is incremental',
      () async {
        final client = FakeNotionClient(token);
        final adapter = buildAdapter(client);
        final push = await adapter.push(
          const NotionSyncEntity(
            canonicalId: 'KNW-1',
            type: 'knowledge',
            properties: {'title': 'Fact', 'canonical_id': 'KNW-1'},
          ),
        );

        // Our own writes must not come back as inbound changes.
        final ownEcho = await adapter.pull();
        expect(ownEcho.changes, isEmpty);
        adapter.acknowledge(ownEcho);

        // A human edits the page directly in Notion (foreign origin).
        client.simulateRemoteEdit(push.pageId, {
          'title': 'Fact edited in Notion',
          'canonical_id': 'KNW-1',
        });
        final inbound = await adapter.pull();
        expect(inbound.changes, hasLength(1));
        expect(inbound.changes.single.canonicalId, 'KNW-1');
        expect(
          inbound.changes.single.properties['title'],
          'Fact edited in Notion',
        );
        expect(inbound.changes.single.type, 'knowledge');
        // Acknowledge only after the caller reconciled it into Git.
        adapter.acknowledge(inbound);

        // Incremental cursor: a repeat pull with no new edits is empty.
        expect((await adapter.pull()).changes, isEmpty);
      },
    );

    test(
      'conflicting remote edit is explicit and never silently overwritten',
      () async {
        final client = FakeNotionClient(token);
        final adapter = buildAdapter(client);
        final push = await adapter.push(
          const NotionSyncEntity(
            canonicalId: 'REF-1',
            type: 'reference',
            properties: {'title': 'v1'},
          ),
        );
        // A third party edits the page after our last sync base.
        client.simulateRemoteEdit(push.pageId, {'title': 'human edit'});

        await expectLater(
          adapter.push(
            const NotionSyncEntity(
              canonicalId: 'REF-1',
              type: 'reference',
              properties: {'title': 'v2', 'ignored_private': 'do not copy'},
            ),
          ),
          throwsA(isA<NotionConflict>()),
        );
        // The human's edit survives — no silent overwrite.
        expect(
          (await client.page(token, push.pageId))!.properties['title'],
          'human edit',
        );
      },
    );

    test(
      'conflict carries immutable allowlisted Git and Notion snapshots',
      () async {
        final client = FakeNotionClient(token);
        final adapter = buildAdapter(client);
        final push = await adapter.push(
          const NotionSyncEntity(
            canonicalId: 'REF-snapshot',
            type: 'reference',
            properties: {'title': 'Git', 'ignored_private': 'git-private'},
          ),
        );
        client.simulateRemoteEdit(push.pageId, {
          'title': 'Notion',
          'ignored_private': 'notion-private',
        });

        NotionConflict? conflict;
        try {
          await adapter.push(
            const NotionSyncEntity(
              canonicalId: 'REF-snapshot',
              type: 'reference',
              properties: {
                'title': 'Git next',
                'ignored_private': 'git-private',
              },
            ),
          );
        } on NotionConflict catch (error) {
          conflict = error;
        }

        final snapshot = conflict!.snapshot!;
        expect(snapshot.conflictId, 'REF-snapshot@${snapshot.remoteRevision}');
        expect(snapshot.gitProperties, {'title': 'Git next'});
        expect(snapshot.notionProperties, {'title': 'Notion'});
        expect(
          () => snapshot.gitProperties['title'] = 'mutated',
          throwsUnsupportedError,
        );
      },
    );

    test(
      'reviewed Keep Git is fenced to the inspected remote revision',
      () async {
        final client = FakeNotionClient(token);
        final adapter = buildAdapter(client);
        final push = await adapter.push(
          const NotionSyncEntity(
            canonicalId: 'REF-fence',
            type: 'reference',
            properties: {'title': 'Git'},
          ),
        );
        client.simulateRemoteEdit(push.pageId, {'title': 'reviewed'});
        NotionConflict? conflict;
        try {
          await adapter.push(
            const NotionSyncEntity(
              canonicalId: 'REF-fence',
              type: 'reference',
              properties: {'title': 'Git next'},
            ),
          );
        } on NotionConflict catch (error) {
          conflict = error;
        }
        client.simulateRemoteEdit(push.pageId, {'title': 'newer'});

        await expectLater(
          adapter.resolveKeepGit(conflict!.snapshot!),
          throwsA(isA<NotionConflict>()),
        );
        expect(
          (await client.page(token, push.pageId))!.properties['title'],
          'newer',
        );
      },
    );

    test('optimistic concurrency rejects a stale write', () async {
      final client = FakeNotionClient(token);
      final page = await client.createPage(
        token,
        databaseId: 'db_task',
        canonicalId: 'TSK-2',
        origin: 'under-claw-work',
        properties: const {'title': 'v0'},
      );
      // First writer wins.
      await client.updatePage(
        token,
        pageId: page.pageId,
        expectedRevision: page.revision,
        origin: 'under-claw-work',
        properties: const {'title': 'w1'},
      );
      // Second writer used the same (now stale) revision -> conflict.
      expect(
        () => client.updatePage(
          token,
          pageId: page.pageId,
          expectedRevision: page.revision,
          origin: 'under-claw-work',
          properties: const {'title': 'w2'},
        ),
        throwsA(isA<NotionConflict>()),
      );
    });

    test(
      'deletion policy soft-archives and never destroys remote data',
      () async {
        final client = FakeNotionClient(token);
        final adapter = buildAdapter(client);
        final push = await adapter.push(
          const NotionSyncEntity(
            canonicalId: 'OBJ-1',
            type: 'objective',
            properties: {'title': 'Objective'},
          ),
        );
        final archived = await adapter.archive(
          const NotionSyncEntity(
            canonicalId: 'OBJ-1',
            type: 'objective',
            properties: {'title': 'Objective'},
          ),
        );
        expect(archived.archived, isTrue);
        final page = await client.page(token, push.pageId);
        expect(page, isNotNull);
        expect(page!.archived, isTrue);
      },
    );

    test(
      'restart re-binds by canonical id instead of duplicating (g3)',
      () async {
        final client = FakeNotionClient(token);
        // First run: a fresh installation pushes an entity and creates its page.
        final first = NotionSyncAdapter(
          client: client,
          secretStore: FakeNotionSecretStore(token),
          secretRef: secretRef,
          databases: databases,
          installationId: 'inst-restart',
        );
        final created = await first.push(
          const NotionSyncEntity(
            canonicalId: 'KNW-restart',
            type: 'knowledge',
            properties: {'title': 'v1'},
          ),
        );
        expect(created.created, isTrue);

        // Restart: a brand-new adapter with an EMPTY sync state (sidecar lost)
        // must not mint a duplicate page — it rebinds by canonical_id lookup.
        final afterRestart = NotionSyncAdapter(
          client: client,
          secretStore: FakeNotionSecretStore(token),
          secretRef: secretRef,
          databases: databases,
          installationId: 'inst-restart',
        );
        final again = await afterRestart.push(
          const NotionSyncEntity(
            canonicalId: 'KNW-restart',
            type: 'knowledge',
            properties: {'title': 'v2'},
          ),
        );
        expect(again.created, isFalse);
        expect(again.pageId, created.pageId);
      },
    );

    test(
      'sync state survives a restart via the persistable sidecar (g3)',
      () async {
        final client = FakeNotionClient(token);
        final adapter = buildAdapter(client);
        final created = await adapter.push(
          const NotionSyncEntity(
            canonicalId: 'DOM-persist',
            type: 'domain',
            properties: {'title': 'v1'},
          ),
        );
        // Round-trip the sidecar through JSON (as a restart would).
        final rehydrated = NotionSyncState.fromJson(adapter.state.toJson());
        expect(rehydrated.canonicalToPage['DOM-persist'], created.pageId);
        expect(rehydrated.baseRevision['DOM-persist'], created.revision);
      },
    );

    test('a peer installation is not self-echoed and conflicts (g4)', () async {
      final client = FakeNotionClient(token);
      NotionSyncAdapter make(String id) => NotionSyncAdapter(
        client: client,
        secretStore: FakeNotionSecretStore(token),
        secretRef: secretRef,
        databases: databases,
        installationId: id,
      );
      final a = make('inst-A');
      final b = make('inst-B');

      await a.push(
        const NotionSyncEntity(
          canonicalId: 'KNW-peer',
          type: 'knowledge',
          properties: {'title': 'from A'},
        ),
      );
      // B must see A's write as a foreign inbound change, not its own echo.
      final inbound = await b.pull();
      expect(inbound.changes.map((c) => c.canonicalId), contains('KNW-peer'));
      b.acknowledge(inbound);

      // B edits the same page; A's stale-based push is an explicit conflict —
      // A never silently overwrites B's change.
      await b.push(
        const NotionSyncEntity(
          canonicalId: 'KNW-peer',
          type: 'knowledge',
          properties: {'title': 'from B'},
        ),
      );
      expect(
        () => a.push(
          const NotionSyncEntity(
            canonicalId: 'KNW-peer',
            type: 'knowledge',
            properties: {'title': 'A again'},
          ),
        ),
        throwsA(isA<NotionConflict>()),
      );
    });

    test('inbound change is redelivered until acknowledged (g5)', () async {
      final client = FakeNotionClient(token);
      final adapter = buildAdapter(client);
      final push = await adapter.push(
        const NotionSyncEntity(
          canonicalId: 'DOM-g5',
          type: 'domain',
          properties: {'title': 'v1'},
        ),
      );
      client.simulateRemoteEdit(push.pageId, {'title': 'edited'});

      // A pull surfaces the change but advances no cursor.
      final first = await adapter.pull();
      expect(first.changes, hasLength(1));
      // Caller "fails" to apply -> does not acknowledge -> redelivered verbatim.
      final second = await adapter.pull();
      expect(second.changes.map((c) => c.canonicalId), ['DOM-g5']);
      // Only after a successful Git apply does the caller acknowledge.
      adapter.acknowledge(second);
      expect((await adapter.pull()).changes, isEmpty);
    });

    test('unauthorized token is rejected by the client', () async {
      final client = FakeNotionClient(token);
      expect(
        () => client.createPage(
          'WRONG-TOKEN',
          databaseId: 'db_task',
          canonicalId: 'TSK-3',
          origin: 'under-claw-work',
          properties: const {},
        ),
        throwsA(isA<NotionSyncException>()),
      );
    });
  });

  group('Notion schema mapping (requirement 5)', () {
    late Directory temporary;
    late Workspace workspace;
    late EntityService entities;

    setUp(() {
      temporary = Directory.systemTemp.createTempSync('under-claw-notion-');
      workspace = Workspace(temporary)..ensureLayout();
      entities = EntityService(workspace);
    });

    tearDown(() => temporary.deleteSync(recursive: true));

    test('maps canonical entities, relations and review state', () async {
      const mapper = NotionEntityMapper();
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

      final domainSync = mapper.fromCanonical(domain);
      expect(domainSync.type, 'domain');
      expect(domainSync.properties['canonical_id'], domain.id);
      expect(domainSync.properties['title'], 'Product');

      // A match carries its review state into Notion properties.
      final match = MatchService(workspace).propose(
        subjectId: knowledge.id,
        targetId: milestone.id,
        actorType: 'user',
        actorId: 'user:jsj',
      );
      final matchSync = mapper.fromCanonical(match.entity);
      expect(matchSync.type, 'match');
      expect(matchSync.properties['review_state'], 'proposed');

      // A Task maps its relations (domain/milestone/objectives).
      final taskSync = mapper.fromTask(
        WorkTask(
          id: 'TSK-map',
          domainId: domain.id,
          milestoneId: milestone.id,
          title: 'Mapped task',
          status: TaskStatus.draft,
          promptDraft: '',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: 'ENV-x',
          alignedObjectiveIds: const ['OBJ-1'],
        ),
      );
      final relations = taskSync.properties['relations'] as Map;
      expect(relations['domain_id'], domain.id);
      expect(relations['milestone_id'], milestone.id);
      expect(relations['objective_ids'], const ['OBJ-1']);
    });
  });

  group('Notion inbound reconciliation into Git canonical (gap g6)', () {
    late Directory temporary;
    late Workspace workspace;
    late EntityService entities;
    late FakeNotionClient client;
    late NotionSyncAdapter adapter;

    const host = EnvironmentIdentity(
      machineKey: 'MK-recon',
      os: 'macos',
      architecture: 'macosArm64',
    );

    setUp(() {
      temporary = Directory.systemTemp.createTempSync('under-claw-recon-');
      workspace = Workspace(temporary)..ensureLayout();
      entities = EntityService(workspace);
      client = FakeNotionClient(token);
      adapter = NotionSyncAdapter(
        client: client,
        secretStore: FakeNotionSecretStore(token),
        secretRef: secretRef,
        databases: databases,
        installationId: 'inst-recon',
      );
    });

    tearDown(() => temporary.deleteSync(recursive: true));

    test(
      'a Notion title edit round-trips to Git preserving id/relations',
      () async {
        const mapper = NotionEntityMapper();
        final domain = entities.create(
          kind: EntityKind.domain,
          title: 'Product',
        );
        final milestone = entities.create(
          kind: EntityKind.milestone,
          title: 'MVP',
          domainId: domain.id,
        );
        final knowledge = entities.create(
          kind: EntityKind.knowledge,
          title: 'Original',
          domainId: domain.id,
          milestoneId: milestone.id,
        );

        final push = await adapter.push(mapper.fromCanonical(knowledge));
        // A human edits the title directly in Notion.
        client.simulateRemoteEdit(push.pageId, {'title': 'Edited in Notion'});
        final pull = await adapter.pull();
        expect(pull.changes, hasLength(1));

        final reconciler = NotionCanonicalReconciler(workspace);
        final result = reconciler.apply(pull.changes.single);
        expect(result.action, 'updated');
        adapter.acknowledge(pull);

        // Git canonical now carries the new title; id, type and relations survive.
        final updated = CanonicalRepository(
          workspace,
        ).get(EntityKind.knowledge, knowledge.id)!;
        expect(updated.data['title'], 'Edited in Notion');
        expect(updated.id, knowledge.id);
        expect((updated.data['scope'] as Map)['milestone_id'], milestone.id);
        expect(updated.data['relations'], isNotNull);
      },
    );

    test(
      'an inbound Match review_state change is an explicit conflict',
      () async {
        final domain = entities.create(
          kind: EntityKind.domain,
          title: 'Product',
        );
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
        final change = NotionInboundChange(
          canonicalId: match.id,
          pageId: 'p1',
          type: 'match',
          properties: const {'review_state': 'approved'},
          archived: false,
          remoteRevision: "1",
          origin: 'notion-user',
        );
        expect(
          () => NotionCanonicalReconciler(workspace).apply(change),
          throwsA(isA<NotionReconcileConflict>()),
        );
        // Git review state is authoritative and was NOT silently overwritten.
        expect(MatchService(workspace).get(match.id)!.reviewState, 'proposed');
      },
    );

    test('an Environment alias edited in Notion reconciles into Git', () async {
      final env = EnvironmentService(
        workspace,
      ).register(identity: host, alias: 'Old');
      final change = NotionInboundChange(
        canonicalId: env.id,
        pageId: 'p1',
        type: 'environment',
        properties: const {'title': 'New alias'},
        archived: false,
        remoteRevision: "1",
        origin: 'notion-user',
      );
      NotionCanonicalReconciler(workspace).apply(change);
      final reloaded = EnvironmentService(workspace).get(env.id)!;
      expect(reloaded.alias, 'New alias');
      // The immutable id is preserved through the inbound reconcile.
      expect(reloaded.id, env.id);
    });

    test('an Agent name edited in Notion reconciles into Git', () async {
      final env = EnvironmentService(
        workspace,
      ).register(identity: host, alias: 'Host');
      final agent = AgentRegistryService(
        workspace,
      ).register(name: 'Old', kind: 'hermes', environmentId: env.id);
      final change = NotionInboundChange(
        canonicalId: agent.id,
        pageId: 'p1',
        type: 'agent',
        properties: const {'title': 'Renamed'},
        archived: false,
        remoteRevision: "1",
        origin: 'notion-user',
      );
      NotionCanonicalReconciler(workspace).apply(change);
      final reloaded = AgentRegistryService(workspace).get(agent.id)!;
      expect(reloaded.name, 'Renamed');
      expect(reloaded.environmentId, env.id);
    });
  });

  group('Notion sync sidecar persistence (g5)', () {
    late Directory temporary;

    setUp(
      () => temporary = Directory.systemTemp.createTempSync('under-claw-side-'),
    );
    tearDown(() => temporary.deleteSync(recursive: true));

    File sidecar() => File('${temporary.path}/notion-sync.json');

    test(
      'installation id is generated once and fixed across restarts',
      () async {
        final store = NotionSyncStore(sidecar());
        // First run: sidecar absent -> create + persist a fresh, fixed id.
        final first = store.loadOrCreate();
        expect(sidecar().existsSync(), isTrue);
        final id = first.installationId;
        expect(id, startsWith('inst-'));

        // Restart: a brand-new store over the SAME file must reload the SAME id.
        final second = NotionSyncStore(sidecar()).loadOrCreate();
        expect(second.installationId, id);
      },
    );

    test(
      'state (mapping + cursor + id) round-trips through the sidecar file',
      () async {
        final client = FakeNotionClient(token);
        final store = NotionSyncStore(sidecar());
        final state = store.loadOrCreate();
        final adapter = NotionSyncAdapter(
          client: client,
          secretStore: FakeNotionSecretStore(token),
          secretRef: secretRef,
          databases: databases,
          state: state,
        );
        final created = await adapter.push(
          const NotionSyncEntity(
            canonicalId: 'DOM-side',
            type: 'domain',
            properties: {'title': 'v1'},
          ),
        );
        // Persist atomically (temp file then rename) after the push.
        store.save(adapter.state);

        // Restart: reload the sidecar and rebuild the adapter from it.
        final reloaded = NotionSyncStore(sidecar()).loadOrCreate();
        expect(reloaded.installationId, adapter.installationId);
        expect(reloaded.canonicalToPage['DOM-side'], created.pageId);
        expect(reloaded.baseRevision['DOM-side'], created.revision);
        expect(reloaded.pullCursor, adapter.state.pullCursor);

        // The reloaded installation id still echo-skips its own prior write.
        final resumed = NotionSyncAdapter(
          client: client,
          secretStore: FakeNotionSecretStore(token),
          secretRef: secretRef,
          databases: databases,
          state: reloaded,
        );
        expect((await resumed.pull()).changes, isEmpty);
      },
    );

    test('a corrupt sidecar is replaced, not fatal', () async {
      sidecar().writeAsStringSync('{ this is not valid json');
      final state = NotionSyncStore(sidecar()).loadOrCreate();
      expect(state.installationId, startsWith('inst-'));
      expect(state.canonicalToPage, isEmpty);
    });
  });
}
