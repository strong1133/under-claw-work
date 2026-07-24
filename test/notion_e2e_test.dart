import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';

/// End-to-end Flutter <-> Notion co-management (requirement 5 / g7), driven
/// entirely by the in-memory fake so it is credential-free and network-free —
/// but with a **real** Git repository: the temp workspace is `git init`ed and
/// every inbound edit is durably `git add`/`git commit`ed before the pull is
/// acknowledged.
///
/// It exercises the full inbound loop: a human edit in Notion -> pull ->
/// validate/merge into Git canonical through the same Core services the UI uses
/// -> apply to the work tree -> **git commit** -> only then acknowledge (cursor
/// advances). The failure path drives a genuinely broken repo so the Git commit
/// returns non-zero; the change is then redelivered until a durable Git commit
/// actually succeeds, proving no inbound edit is ever silently lost.
void main() {
  const token = 'PLACEHOLDER-e2e-token-do-not-leak';
  const secretRef = NotionSecretRef('os-secure-store://under-claw-work/notion');
  const databases = NotionDatabaseMap({
    'domain': 'db_domain',
    'milestone': 'db_milestone',
    'knowledge': 'db_knowledge',
    'task': 'db_task',
  });

  late Directory root;
  late Workspace workspace;
  late EntityService entities;
  late FakeNotionClient client;
  late NotionSyncAdapter adapter;
  late GitSyncService git;
  const mapper = NotionEntityMapper();

  Future<ProcessResult> runGit(List<String> args) =>
      Process.run('git', args, workingDirectory: root.path, runInShell: false);

  // Initialises a self-contained Git repo in the temp workspace with a local
  // identity so `git commit` succeeds without touching any global config or the
  // real project repository.
  Future<void> gitInit() async {
    await runGit(['init']);
    await runGit(['config', 'user.email', 'e2e@under-claw.test']);
    await runGit(['config', 'user.name', 'Under Claw E2E']);
    await runGit(['config', 'commit.gpgsign', 'false']);
  }

  Future<String> committer() =>
      git.commitCanonical(message: 'notion: reconcile inbound edit');

  setUp(() async {
    root = Directory.systemTemp.createTempSync('under-claw-e2e-');
    workspace = Workspace(root)..ensureLayout();
    entities = EntityService(workspace);
    client = FakeNotionClient(token);
    git = GitSyncService(workspace);
    adapter = NotionSyncAdapter(
      client: client,
      secretStore: FakeNotionSecretStore(token),
      secretRef: secretRef,
      databases: databases,
      installationId: 'inst-e2e',
    );
    await gitInit();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'inbound edit reconciles into Git, is committed, then acknowledge advances '
    'cursor',
    () async {
      // Flutter authors canonical state and mirrors it out to Notion.
      final domain = entities.create(kind: EntityKind.domain, title: 'Product');
      final push = await adapter.push(mapper.fromCanonical(domain));

      // A human edits the page directly in Notion.
      client.simulateRemoteEdit(push.pageId, {
        'title': 'Product (edited in Notion)',
        'canonical_id': domain.id,
      });

      // Pull surfaces the inbound change but advances no cursor yet.
      final pull = await adapter.pull();
      expect(pull.changes, hasLength(1));

      // No commit exists before the loop runs.
      expect((await runGit(['rev-parse', 'HEAD'])).exitCode, isNot(0));

      // Reconcile -> real git add/commit -> acknowledge, all bound together.
      final head = await adapter.reconcileAndAcknowledge(
        pull,
        reconciler: NotionCanonicalReconciler(workspace),
        commit: committer,
      );

      // A real commit now exists in the temp repo and matches the returned hash.
      final rev = await runGit(['rev-parse', 'HEAD']);
      expect(rev.exitCode, 0);
      expect(rev.stdout.toString().trim(), head);
      // The commit actually carries the merged canonical file.
      final show = await runGit(['show', '--stat', 'HEAD']);
      expect(show.stdout.toString(), contains('workdb/domains/${domain.id}'));

      // The work tree carries the merged edit; id/relations survive.
      final merged = CanonicalRepository(
        workspace,
      ).get(EntityKind.domain, domain.id)!;
      expect(merged.data['title'], 'Product (edited in Notion)');
      expect(merged.id, domain.id);

      // Cursor advanced -> the same change is not redelivered.
      expect((await adapter.pull()).changes, isEmpty);
    },
  );

  test(
    'a failed Git commit is not acknowledged and the change redelivers until a '
    'commit succeeds',
    () async {
      final domain = entities.create(kind: EntityKind.domain, title: 'Product');
      final milestone = entities.create(
        kind: EntityKind.milestone,
        title: 'MVP',
        domainId: domain.id,
      );
      final push = await adapter.push(mapper.fromCanonical(milestone));
      client.simulateRemoteEdit(push.pageId, {
        'title': 'MVP (renamed)',
        'canonical_id': milestone.id,
      });

      // First delivery: break the repo so the durable Git commit genuinely
      // fails (not a mocked skip). reconcileAndAcknowledge must throw and, most
      // importantly, must NOT advance the cursor.
      Directory(p.join(root.path, '.git')).deleteSync(recursive: true);
      final first = await adapter.pull();
      expect(first.changes.single.canonicalId, milestone.id);
      await expectLater(
        adapter.reconcileAndAcknowledge(
          first,
          reconciler: NotionCanonicalReconciler(workspace),
          commit: committer,
        ),
        throwsA(anything),
      );

      // Because commit failed, the cursor did not move: the identical change is
      // redelivered on the next pull.
      final second = await adapter.pull();
      expect(second.changes.single.canonicalId, milestone.id);

      // Repair the repo; now the durable Git commit succeeds and only then does
      // acknowledge advance the cursor.
      await gitInit();
      final head = await adapter.reconcileAndAcknowledge(
        second,
        reconciler: NotionCanonicalReconciler(workspace),
        commit: committer,
      );
      expect(head, isNotEmpty);

      // A real HEAD commit exists and the redelivery has stopped.
      final rev = await runGit(['rev-parse', 'HEAD']);
      expect(rev.exitCode, 0);
      expect(rev.stdout.toString().trim(), head);
      expect((await adapter.pull()).changes, isEmpty);

      final merged = CanonicalRepository(
        workspace,
      ).get(EntityKind.milestone, milestone.id)!;
      expect(merged.data['title'], 'MVP (renamed)');
    },
  );

  test(
    'an unknown-entity inbound change is an explicit conflict, not silent',
    () {
      // A Notion page references a canonical id that does not exist in Git.
      final change = NotionInboundChange(
        canonicalId: 'DOM-ghost',
        pageId: 'p-ghost',
        type: 'domain',
        properties: const {'title': 'Ghost'},
        archived: false,
        remoteRevision: "1",
        origin: 'notion-user',
      );
      expect(
        () => NotionCanonicalReconciler(workspace).apply(change),
        throwsA(isA<NotionReconcileConflict>()),
      );
      // Because apply threw, the caller never acknowledges; the change would be
      // redelivered on the next pull instead of being lost.
    },
  );
}
