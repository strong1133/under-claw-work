import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'agent_registry_service.dart';
import 'canonical_repository.dart';
import 'entity_service.dart';
import 'environment_service.dart';
import 'match_service.dart';
import 'models.dart';
import 'task_repository.dart';
import 'workspace.dart';

/// Notion two-way sync (requirement 5) — Core contract + in-memory fake.
///
/// Notion is **not** a canonical store: Git remains the single source of truth
/// and this adapter mirrors canonical entities into a Notion workspace and
/// reconciles inbound edits back for the caller to write into Git. Everything
/// here is credential-free and network-free: the real Notion API is fronted by
/// [NotionClient], and tests drive [FakeNotionClient]. No real token, host, or
/// workspace id is ever hard-coded — credentials live only behind
/// [NotionSecretStore] (an OS secure-store abstraction).

/// Opaque locator for a credential held in the OS secure store. This is a
/// pointer, never the secret; it is safe to keep in config/logs. The token it
/// resolves to must never be written to Git, SQLite, logs, or fixtures.
class NotionSecretRef {
  const NotionSecretRef(this.locator);

  /// e.g. `os-secure-store://under-claw-work/notion` (a placeholder, not a
  /// secret).
  final String locator;
}

/// Abstraction over the OS secure store. The token is resolved transiently for
/// the duration of a single API call and is never persisted by the adapter.
abstract interface class NotionSecretStore {
  Future<String?> readToken(NotionSecretRef ref);
  Future<void> writeToken(NotionSecretRef ref, String token);
  Future<void> deleteToken(NotionSecretRef ref);
}

/// Test/dev double for the secure store. Holds a PLACEHOLDER token only — never
/// a real credential.
class FakeNotionSecretStore implements NotionSecretStore {
  FakeNotionSecretStore([
    this.placeholderToken = 'PLACEHOLDER-fake-notion-token',
  ]);

  String? placeholderToken;

  @override
  Future<String?> readToken(NotionSecretRef ref) async => placeholderToken;

  @override
  Future<void> writeToken(NotionSecretRef ref, String token) async {
    placeholderToken = token;
  }

  @override
  Future<void> deleteToken(NotionSecretRef ref) async {
    placeholderToken = null;
  }
}

class NotionSyncException implements Exception {
  const NotionSyncException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'NotionSyncException: $message';
}

/// Raised when a remote page diverged from our last-synced base and would be
/// silently overwritten. Conflicts are always explicit — the adapter never
/// blind-writes over a concurrent Notion edit.
class NotionConflict implements Exception {
  const NotionConflict(
    this.canonicalId,
    this.baseRevision,
    this.remoteRevision, [
    this.snapshot,
  ]);
  final String canonicalId;
  final String baseRevision;
  final String remoteRevision;
  final NotionConflictSnapshot? snapshot;
  @override
  String toString() =>
      'NotionConflict($canonicalId: base=$baseRevision remote=$remoteRevision)';
}

/// Immutable, review-safe view of one divergent Git/Notion entity.
class NotionConflictSnapshot {
  NotionConflictSnapshot({
    required this.canonicalId,
    required this.type,
    required this.pageId,
    required this.baseRevision,
    required this.remoteRevision,
    required Map<String, Object?> gitProperties,
    required Map<String, Object?> notionProperties,
    required this.gitArchived,
    required this.archived,
  }) : gitProperties = _freezeMap(_allowlisted(gitProperties)),
       notionProperties = _freezeMap(_allowlisted(notionProperties));

  static const _allowedProperties = {
    'canonical_id',
    'type',
    'title',
    'status',
    'review_state',
    'relations',
    'kind',
    'machine_key',
    'capabilities',
  };

  final String canonicalId;
  final String type;
  final String pageId;
  final String baseRevision;
  final String remoteRevision;
  final Map<String, Object?> gitProperties;
  final Map<String, Object?> notionProperties;
  final bool gitArchived;
  final bool archived;

  String get conflictId => '$canonicalId@$remoteRevision';

  static Map<String, Object?> _allowlisted(Map<String, Object?> properties) => {
    for (final entry in properties.entries)
      if (_allowedProperties.contains(entry.key)) entry.key: entry.value,
  };

  static Map<String, Object?> _freezeMap(Map<String, Object?> value) =>
      Map.unmodifiable({
        for (final entry in value.entries) entry.key: _freeze(entry.value),
      });

  static Object? _freeze(Object? value) {
    if (value is Map) {
      return Map.unmodifiable({
        for (final entry in value.entries)
          entry.key.toString(): _freeze(entry.value),
      });
    }
    if (value is List) return List.unmodifiable(value.map(_freeze));
    return value;
  }
}

/// Maps canonical entity types to Notion database ids. Ids are injected, never
/// hard-coded, so no specific workspace is baked into Core.
class NotionDatabaseMap {
  const NotionDatabaseMap(this._byType);

  final Map<String, String> _byType;

  String databaseFor(String type) {
    final id = _byType[type];
    if (id == null) {
      throw NotionSyncException('No Notion database mapped for type "$type".');
    }
    return id;
  }

  bool supports(String type) => _byType.containsKey(type);
  Iterable<String> get types => _byType.keys;
}

/// A canonical entity normalized into Notion-shaped properties for one sync.
class NotionSyncEntity {
  const NotionSyncEntity({
    required this.canonicalId,
    required this.type,
    required this.properties,
    this.deleted = false,
  });

  final String canonicalId;
  final String type;
  final Map<String, Object?> properties;

  /// A tombstone: Notion deletion policy is soft-archive, never destroy.
  final bool deleted;
}

/// One fake Notion page. In the real API this is a page in a database.
class NotionRemotePage {
  NotionRemotePage({
    required this.pageId,
    required this.databaseId,
    required this.canonicalId,
    required this.revision,
    required this.origin,
    required this.properties,
    this.archived = false,
  });

  final String pageId;
  final String databaseId;

  /// The canonical id this page mirrors, stored as a Notion property so the
  /// mapping survives even if the local sidecar is lost.
  final String canonicalId;

  /// Monotonic per-workspace revision (stands in for Notion's `last_edited`).
  String revision;

  /// Marker of who last wrote this page. Our own marker is skipped on pull to
  /// break echo loops.
  String origin;
  Map<String, Object?> properties;
  bool archived;

  NotionRemotePage copy() => NotionRemotePage(
    pageId: pageId,
    databaseId: databaseId,
    canonicalId: canonicalId,
    revision: revision,
    origin: origin,
    properties: Map<String, Object?>.from(properties),
    archived: archived,
  );
}

/// The Notion API surface the adapter needs. The real implementation would call
/// api.notion.com; [FakeNotionClient] implements it in memory.
abstract interface class NotionClient {
  Future<NotionRemotePage> createPage(
    String token, {
    required String databaseId,
    required String canonicalId,
    required String origin,
    required Map<String, Object?> properties,
  });

  Future<NotionRemotePage> updatePage(
    String token, {
    required String pageId,
    required String expectedRevision,
    required String origin,
    Map<String, Object?>? properties,
    bool? archived,
  });

  Future<NotionRemotePage?> page(String token, String pageId);

  /// Authoritative rebind lookup (g3): find the single non-archived page that
  /// mirrors [canonicalId], stored as a Notion property. This lets a restarted
  /// process re-bind to the existing page instead of creating a duplicate, even
  /// when the local sync sidecar was lost.
  Future<NotionRemotePage?> pageByCanonicalId(String token, String canonicalId);

  /// Incremental read: pages whose revision is greater than [sinceCursor],
  /// oldest-first, plus the new high-water cursor.
  Future<({List<NotionRemotePage> pages, String cursor})> changesSince(
    String token,
    String sinceCursor,
  );

  Future<void> verifyConnection(String token);
}

/// In-memory fake Notion workspace for contract tests. It authenticates every
/// call against an expected token but never stores that token anywhere.
class FakeNotionClient implements NotionClient {
  FakeNotionClient(this.expectedToken);

  final String expectedToken;
  final Map<String, NotionRemotePage> _pages = {};

  /// Human-readable call log used by tests to prove the token is never leaked.
  final List<String> callLog = [];

  int _pageSeq = 0;
  int _cursor = 0;

  void _auth(String token) {
    if (token != expectedToken) {
      throw const NotionSyncException('Unauthorized: bad Notion token.');
    }
    // The token is used only to authorize; it is deliberately never appended to
    // callLog or stored on any page.
  }

  @override
  Future<NotionRemotePage> createPage(
    String token, {
    required String databaseId,
    required String canonicalId,
    required String origin,
    required Map<String, Object?> properties,
  }) async {
    _auth(token);
    final pageId = 'ntn_${(++_pageSeq).toString().padLeft(6, '0')}';
    final page = NotionRemotePage(
      pageId: pageId,
      databaseId: databaseId,
      canonicalId: canonicalId,
      revision: '${++_cursor}',
      origin: origin,
      properties: Map<String, Object?>.from(properties),
    );
    _pages[pageId] = page;
    callLog.add('create $pageId canonical=$canonicalId origin=$origin');
    return page.copy();
  }

  @override
  Future<NotionRemotePage> updatePage(
    String token, {
    required String pageId,
    required String expectedRevision,
    required String origin,
    Map<String, Object?>? properties,
    bool? archived,
  }) async {
    _auth(token);
    final page = _pages[pageId];
    if (page == null) {
      throw NotionSyncException('No such Notion page: $pageId');
    }
    if (page.revision != expectedRevision) {
      // Optimistic concurrency: someone edited between our read and write.
      throw NotionConflict(page.canonicalId, expectedRevision, page.revision);
    }
    if (properties != null) {
      page.properties = Map<String, Object?>.from(properties);
    }
    if (archived != null) page.archived = archived;
    page.origin = origin;
    page.revision = '${++_cursor}';
    callLog.add('update $pageId rev=${page.revision} origin=$origin');
    return page.copy();
  }

  @override
  Future<NotionRemotePage?> page(String token, String pageId) async {
    _auth(token);
    return _pages[pageId]?.copy();
  }

  @override
  Future<NotionRemotePage?> pageByCanonicalId(
    String token,
    String canonicalId,
  ) async {
    _auth(token);
    final match = _pages.values
        .where((page) => page.canonicalId == canonicalId && !page.archived)
        .firstOrNull;
    return match?.copy();
  }

  @override
  Future<({List<NotionRemotePage> pages, String cursor})> changesSince(
    String token,
    String sinceCursor,
  ) async {
    _auth(token);
    final cursor = int.tryParse(sinceCursor) ?? 0;
    final pages =
        _pages.values
            .where((page) => (int.tryParse(page.revision) ?? 0) > cursor)
            .toList()
          ..sort(
            (a, b) => (int.tryParse(a.revision) ?? 0).compareTo(
              int.tryParse(b.revision) ?? 0,
            ),
          );
    return (pages: [for (final page in pages) page.copy()], cursor: '$_cursor');
  }

  @override
  Future<void> verifyConnection(String token) async => _auth(token);

  /// Test helper: simulate a human editing a page directly in Notion. The edit
  /// carries a foreign origin so the adapter treats it as inbound, not echo.
  NotionRemotePage simulateRemoteEdit(
    String pageId,
    Map<String, Object?> properties, {
    String origin = 'notion-user',
  }) {
    final page = _pages[pageId];
    if (page == null) throw NotionSyncException('No such page: $pageId');
    page.properties = Map<String, Object?>.from(properties);
    page.origin = origin;
    page.revision = '${++_cursor}';
    return page.copy();
  }
}

/// Local, non-canonical sync sidecar: the canonical<->page mapping, the base
/// revision we last agreed on per entity, and the incremental pull cursor.
/// Kept out of Git canonical (it is a projection, rebuildable from the mapping
/// property Notion itself stores).
class NotionSyncState {
  NotionSyncState({String? installationId})
    : installationId = installationId ?? generateInstallationId();

  final Map<String, String> canonicalToPage = {};
  final Map<String, String> pageToCanonical = {};
  final Map<String, String> baseRevision = {};
  String pullCursor = '';

  /// Stable per-installation client identity, persisted in the sidecar JSON so
  /// it is fixed after first creation (g5). Two Flutter instances therefore keep
  /// *distinct* ids across restarts, so one instance's echo is never mistaken
  /// for the other's and a peer's edit surfaces as a conflict. Generated exactly
  /// once (on first ever state creation) and never randomised again.
  final String installationId;

  static int _installationSeq = 0;

  /// Mints a fresh, unique installation id. Called at most once per
  /// installation; thereafter the id is loaded from the persisted sidecar.
  static String generateInstallationId() {
    final random = Random.secure();
    final entropy = List<int>.generate(
      6,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'inst-$entropy-${_installationSeq++}';
  }

  void bind(String canonicalId, String pageId, String revision) {
    canonicalToPage[canonicalId] = pageId;
    pageToCanonical[pageId] = canonicalId;
    baseRevision[canonicalId] = revision;
  }

  /// Serializes the mapping so it survives a process restart (g5). The sidecar
  /// is a rebuildable local projection, never Git-canonical, and holds no
  /// secret — only the installation id, canonical ids, page ids and revisions.
  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'installation_id': installationId,
    'pull_cursor': pullCursor,
    'canonical_to_page': canonicalToPage,
    'base_revision': baseRevision,
  };

  /// Rehydrates a persisted sidecar. A persisted `installation_id` is preserved
  /// verbatim (so it stays fixed across restarts); a legacy sidecar without one
  /// mints a fresh id exactly once. Unknown/older mapping shapes degrade to an
  /// empty mapping, in which case the remote canonical-id lookup still prevents
  /// duplicate pages.
  static NotionSyncState fromJson(Map<Object?, Object?> raw) {
    final persistedId = raw['installation_id'];
    final state = NotionSyncState(
      installationId: persistedId is String && persistedId.isNotEmpty
          ? persistedId
          : null,
    );
    final cursor = raw['pull_cursor'];
    if (cursor is String) {
      state.pullCursor = cursor;
    } else if (cursor is int) {
      // Backward-compatible read of the original numeric fake cursor.
      state.pullCursor = '$cursor';
    }
    final mapping = raw['canonical_to_page'];
    if (mapping is Map) {
      final base = raw['base_revision'];
      mapping.forEach((canonicalId, pageId) {
        if (canonicalId is String && pageId is String) {
          final revision = base is Map ? base[canonicalId] : null;
          state.bind(
            canonicalId,
            pageId,
            revision is String ? revision : '${revision is int ? revision : 0}',
          );
        }
      });
    }
    return state;
  }
}

/// Durable, atomic persistence for the [NotionSyncState] sidecar (g5).
///
/// The sidecar lives outside Git canonical (a rebuildable local projection) and
/// is written temp-then-rename so a crash never leaves a half-written file. On
/// first run the file is absent, so a new state is created with a freshly
/// generated installation id and immediately saved — fixing the id from that
/// point on. Every later run [load]s the same id and mapping.
class NotionSyncStore {
  const NotionSyncStore(this.file);

  final File file;

  /// Loads the persisted state, or creates + persists a fresh one (with a new,
  /// now-fixed installation id) when the sidecar does not yet exist. A corrupt
  /// sidecar is treated as absent and replaced rather than crashing the app.
  NotionSyncState loadOrCreate() {
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) {
          return NotionSyncState.fromJson(decoded.cast<Object?, Object?>());
        }
      } on FormatException {
        // Fall through to create a fresh state below.
      }
    }
    final state = NotionSyncState();
    save(state);
    return state;
  }

  /// Atomically writes [state] to the sidecar (temp file then rename).
  void save(NotionSyncState state) {
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(state.toJson())}\n',
      flush: true,
    );
    temporary.renameSync(file.path);
  }
}

class NotionPushResult {
  const NotionPushResult({
    required this.canonicalId,
    required this.pageId,
    required this.created,
    required this.revision,
    required this.archived,
  });
  final String canonicalId;
  final String pageId;
  final bool created;
  final String revision;
  final bool archived;
}

class NotionInboundChange {
  const NotionInboundChange({
    required this.canonicalId,
    required this.pageId,
    required this.type,
    required this.properties,
    required this.archived,
    required this.remoteRevision,
    required this.origin,
  });
  final String canonicalId;
  final String pageId;
  final String type;
  final Map<String, Object?> properties;
  final bool archived;
  final String remoteRevision;
  final String origin;
}

/// A page mapping observed during a pull, applied to sync state only once the
/// caller acknowledges durable Git reconciliation (g5).
class NotionPageBinding {
  const NotionPageBinding(this.canonicalId, this.pageId, this.revision);
  final String canonicalId;
  final String pageId;
  final String revision;
}

class NotionPullResult {
  const NotionPullResult({
    required this.changes,
    required this.cursor,
    this.bindings = const [],
  });

  /// Inbound Notion edits the caller must reconcile into Git canonical.
  final List<NotionInboundChange> changes;

  /// High-water cursor this pull would advance to once acknowledged.
  final String cursor;

  /// Every page mapping (own echoes and foreign edits) seen in this pull,
  /// bound into sync state only by [NotionSyncAdapter.acknowledge].
  final List<NotionPageBinding> bindings;
}

/// Bridges canonical entities and a Notion workspace. Git stays canonical; this
/// adapter mirrors out and reconciles in with idempotency, origin markers,
/// incremental cursors, soft-delete, and explicit conflicts.
class NotionSyncAdapter {
  /// Builds an adapter. The installation id defaults to the (persisted) id of
  /// [state], so a restart that reloads its sidecar keeps the same identity; an
  /// explicit [installationId] wins for tests/peers. A single [NotionSyncState]
  /// backs both `this.state` and `this.installationId` so they can never
  /// diverge.
  factory NotionSyncAdapter({
    required NotionClient client,
    required NotionSecretStore secretStore,
    required NotionSecretRef secretRef,
    required NotionDatabaseMap databases,
    String? installationId,
    NotionSyncState? state,
  }) {
    final resolved = state ?? NotionSyncState(installationId: installationId);
    return NotionSyncAdapter._(
      client: client,
      secretStore: secretStore,
      secretRef: secretRef,
      databases: databases,
      installationId: installationId ?? resolved.installationId,
      state: resolved,
    );
  }

  NotionSyncAdapter._({
    required this.client,
    required this.secretStore,
    required this.secretRef,
    required this.databases,
    required this.installationId,
    required this.state,
  });

  final NotionClient client;
  final NotionSecretStore secretStore;
  final NotionSecretRef secretRef;
  final NotionDatabaseMap databases;

  /// Stable, per-installation client identity (g4). Two Flutter instances on
  /// two machines have *distinct* installation ids, so one instance's write is
  /// never mistaken for the other's echo, and a remote revision moved by the
  /// other instance is correctly surfaced as a conflict instead of being
  /// silently overwritten. The id is persisted in the [NotionSyncState] sidecar
  /// (see [NotionSyncStore]) under `.worklog/`, so it is generated exactly once
  /// on first run and stays fixed across restarts; distinct installations never
  /// collide by accident.
  final String installationId;

  final NotionSyncState state;

  /// Per-operation counter so each write carries a unique origin
  /// `<installationId>#<seq>`, distinguishing individual operations of the same
  /// installation.
  int _operationSeq = 0;

  String _nextOrigin() => '$installationId#${_operationSeq++}';

  /// True when [origin] was stamped by *this* installation (any of its
  /// operations), so its own writes are echo-skipped and never re-applied.
  bool _isOwnOrigin(String origin) =>
      origin == installationId || origin.split('#').first == installationId;

  /// Pushes a canonical entity to Notion. Idempotent by canonical id: an
  /// already-mapped entity updates its page instead of creating a duplicate.
  /// Refuses to overwrite a page a third party edited since our last sync
  /// (raises [NotionConflict]).
  Future<NotionPushResult> push(
    NotionSyncEntity entity, {
    bool overwriteRemote = false,
  }) async {
    final token = await _requireToken();
    final databaseId = databases.databaseFor(entity.type);
    var mappedPageId = state.canonicalToPage[entity.canonicalId];

    // g3: if the local sidecar has no mapping (e.g. after a restart), re-bind
    // authoritatively by looking the page up by its canonical_id property
    // before creating — this prevents a restart from minting a duplicate page.
    if (mappedPageId == null) {
      final existing = await client.pageByCanonicalId(
        token,
        entity.canonicalId,
      );
      if (existing != null) {
        state.bind(existing.canonicalId, existing.pageId, existing.revision);
        mappedPageId = existing.pageId;
      }
    }

    if (mappedPageId == null) {
      final page = await client.createPage(
        token,
        databaseId: databaseId,
        canonicalId: entity.canonicalId,
        origin: _nextOrigin(),
        properties: entity.properties,
      );
      state.bind(entity.canonicalId, page.pageId, page.revision);
      return NotionPushResult(
        canonicalId: entity.canonicalId,
        pageId: page.pageId,
        created: true,
        revision: page.revision,
        archived: page.archived,
      );
    }

    final remote = await client.page(token, mappedPageId);
    if (remote == null) {
      throw NotionSyncException(
        'Mapping points at a missing Notion page: $mappedPageId.',
      );
    }
    final base = state.baseRevision[entity.canonicalId] ?? remote.revision;
    // g4: if the remote moved past our base and the mover was NOT this
    // installation, a human or another client (including another Flutter
    // instance) changed it: surface an explicit conflict rather than clobbering
    // their edit. Only *our own* installation's echo is allowed to fast-forward.
    if (!overwriteRemote &&
        remote.revision != base &&
        !_isOwnOrigin(remote.origin)) {
      throw NotionConflict(
        entity.canonicalId,
        base,
        remote.revision,
        NotionConflictSnapshot(
          canonicalId: entity.canonicalId,
          type: entity.type,
          pageId: remote.pageId,
          baseRevision: base,
          remoteRevision: remote.revision,
          gitProperties: entity.properties,
          notionProperties: remote.properties,
          gitArchived: entity.deleted,
          archived: remote.archived,
        ),
      );
    }
    final page = await client.updatePage(
      token,
      pageId: mappedPageId,
      expectedRevision: remote.revision,
      origin: _nextOrigin(),
      properties: entity.properties,
      archived: entity.deleted,
    );
    state.bind(entity.canonicalId, page.pageId, page.revision);
    return NotionPushResult(
      canonicalId: entity.canonicalId,
      pageId: page.pageId,
      created: false,
      revision: page.revision,
      archived: page.archived,
    );
  }

  /// Deletion policy: never destroy remote data; soft-archive the mapped page.
  Future<NotionPushResult> archive(NotionSyncEntity entity) => push(
    NotionSyncEntity(
      canonicalId: entity.canonicalId,
      type: entity.type,
      properties: entity.properties,
      deleted: true,
    ),
  );

  /// Applies the reviewed Git side only if the remote is still the exact
  /// revision the user reviewed.
  Future<NotionPushResult> resolveKeepGit(
    NotionConflictSnapshot conflict,
  ) async {
    final token = await _requireToken();
    final remote = await client.page(token, conflict.pageId);
    if (remote == null || remote.canonicalId != conflict.canonicalId) {
      throw NotionSyncException(
        'The reviewed Notion page is no longer available for '
        '${conflict.conflictId}.',
      );
    }
    if (remote.revision != conflict.remoteRevision) {
      throw NotionConflict(
        conflict.canonicalId,
        conflict.remoteRevision,
        remote.revision,
      );
    }
    final page = await client.updatePage(
      token,
      pageId: conflict.pageId,
      expectedRevision: conflict.remoteRevision,
      origin: _nextOrigin(),
      properties: conflict.gitProperties,
      archived: conflict.gitArchived,
    );
    state.bind(conflict.canonicalId, page.pageId, page.revision);
    return NotionPushResult(
      canonicalId: conflict.canonicalId,
      pageId: page.pageId,
      created: false,
      revision: page.revision,
      archived: page.archived,
    );
  }

  /// Applies the reviewed Notion side through Core and binds only this page
  /// after the Git commit succeeds. The global pull cursor is never advanced.
  Future<String> resolveApplyNotion(
    NotionConflictSnapshot conflict, {
    required NotionCanonicalReconciler reconciler,
    required Future<String> Function() commit,
  }) async {
    final token = await _requireToken();
    final remote = await client.page(token, conflict.pageId);
    if (remote == null || remote.canonicalId != conflict.canonicalId) {
      throw NotionSyncException(
        'The reviewed Notion page is no longer available for '
        '${conflict.conflictId}.',
      );
    }
    if (remote.revision != conflict.remoteRevision) {
      throw NotionConflict(
        conflict.canonicalId,
        conflict.remoteRevision,
        remote.revision,
      );
    }
    reconciler.apply(
      NotionInboundChange(
        canonicalId: conflict.canonicalId,
        pageId: conflict.pageId,
        type: conflict.type,
        properties: conflict.notionProperties,
        archived: conflict.archived,
        remoteRevision: conflict.remoteRevision,
        origin: remote.origin,
      ),
    );
    final head = await commit();
    state.bind(conflict.canonicalId, conflict.pageId, conflict.remoteRevision);
    return head;
  }

  /// Pulls Notion edits made since the last cursor, skipping pages we ourselves
  /// last wrote (echo-loop prevention). Returns inbound changes for the caller
  /// to reconcile into Git — Notion is not canonical, so this adapter never
  /// writes canonical state itself.
  /// Peeks at Notion edits since the last acknowledged cursor. Crucially (g5)
  /// this is a pure read: it advances **no** cursor and binds **no** mapping.
  /// The caller must fetch → validate/merge into canonical → commit to Git and
  /// only then call [acknowledge]. If the caller fails to apply a change, it
  /// never acknowledges, so the same change is redelivered on the next pull and
  /// is never silently lost.
  Future<NotionPullResult> pull() async {
    final token = await _requireToken();
    final result = await client.changesSince(token, state.pullCursor);
    final changes = <NotionInboundChange>[];
    final bindings = <NotionPageBinding>[];
    for (final page in result.pages) {
      bindings.add(
        NotionPageBinding(page.canonicalId, page.pageId, page.revision),
      );
      if (state.baseRevision[page.canonicalId] == page.revision) {
        // The transport deliberately overlaps the high-water timestamp so
        // pages sharing that timestamp cannot be lost. Already acknowledged
        // revisions are filtered here.
        continue;
      }
      if (_isOwnOrigin(page.origin)) {
        // Our own write echoing back — its mapping is bound at acknowledge time
        // but it is never re-emitted as an inbound change (echo-loop break).
        continue;
      }
      changes.add(
        NotionInboundChange(
          canonicalId: page.canonicalId,
          pageId: page.pageId,
          type: _typeForDatabase(page.databaseId),
          properties: page.properties,
          archived: page.archived,
          remoteRevision: page.revision,
          origin: page.origin,
        ),
      );
    }
    return NotionPullResult(
      changes: changes,
      cursor: result.cursor,
      bindings: bindings,
    );
  }

  /// Durably commits a pull once the caller has reconciled it into Git (g5):
  /// binds every observed page mapping and advances the pull cursor. Only call
  /// this after the Git write for [result] succeeded.
  void acknowledge(NotionPullResult result) {
    for (final binding in result.bindings) {
      state.bind(binding.canonicalId, binding.pageId, binding.revision);
    }
    state.pullCursor = result.cursor;
  }

  /// Full inbound loop for one pull, with [acknowledge] bound to a durable Git
  /// commit (g5/g7). Each inbound change is reconciled into the Git-canonical
  /// work tree through [reconciler], then [commit] must durably persist that
  /// write (typically [GitSyncService.commitCanonical]) and return the commit
  /// hash. Only if [commit] returns successfully is the pull acknowledged and
  /// the cursor advanced. If reconcile or the Git commit throws, this rethrows
  /// and the cursor is left untouched, so the same change is redelivered on the
  /// next [pull] and no inbound edit is ever silently lost.
  Future<String> reconcileAndAcknowledge(
    NotionPullResult result, {
    required NotionCanonicalReconciler reconciler,
    required Future<String> Function() commit,
  }) async {
    for (final change in result.changes) {
      reconciler.apply(change);
    }
    // A non-zero Git commit (broken repo, nothing staged, rejected write)
    // throws here and short-circuits before acknowledge — cursor stays put.
    final head = await commit();
    acknowledge(result);
    return head;
  }

  Future<String> _requireToken() async {
    final token = await secretStore.readToken(secretRef);
    if (token == null || token.trim().isEmpty) {
      throw const NotionSyncException(
        'Notion credential is unavailable in the OS secure store.',
      );
    }
    return token;
  }

  String _typeForDatabase(String databaseId) {
    for (final type in databases.types) {
      if (databases.databaseFor(type) == databaseId) return type;
    }
    return 'unknown';
  }
}

/// Normalizes canonical documents into Notion-shaped [NotionSyncEntity]
/// properties. Demonstrates the database/schema mapping for every synced type
/// — Domain, Milestone, Objective, Task, Knowledge, Reference, Environment,
/// Agent, Match — including relation and review-state fields.
class NotionEntityMapper {
  const NotionEntityMapper();

  NotionSyncEntity fromCanonical(CanonicalEntity entity) {
    final data = entity.data;
    final relations = <String, Object?>{
      for (final key in const [
        'domain_id',
        'milestone_id',
        'objective_ids',
        'knowledge_ids',
        'reference_ids',
      ])
        if (data[key] != null) key: data[key],
    };
    return NotionSyncEntity(
      canonicalId: entity.id,
      type: entity.kind.type,
      properties: {
        'canonical_id': entity.id,
        'type': entity.kind.type,
        'title': (data['title'] ?? data['name'] ?? entity.id).toString(),
        if (data['status'] != null) 'status': data['status'],
        if (data['review_state'] != null) 'review_state': data['review_state'],
        if (relations.isNotEmpty) 'relations': relations,
      },
    );
  }

  NotionSyncEntity fromTask(WorkTask task) => NotionSyncEntity(
    canonicalId: task.id,
    type: 'task',
    properties: {
      'canonical_id': task.id,
      'type': 'task',
      'title': task.title,
      'status': task.status.name,
      'relations': {
        'domain_id': task.domainId,
        'milestone_id': task.milestoneId,
        if (task.alignedObjectiveIds.isNotEmpty)
          'objective_ids': task.alignedObjectiveIds,
      },
    },
  );

  /// Maps an Environment registry record into Notion properties (g6). The
  /// editable alias is the Notion title; the immutable id/machine key ride along
  /// as properties so the mapping and identity survive a sidecar loss.
  NotionSyncEntity fromEnvironment(EnvironmentRecord record) =>
      NotionSyncEntity(
        canonicalId: record.id,
        type: 'environment',
        properties: {
          'canonical_id': record.id,
          'type': 'environment',
          'title': record.alias,
          'machine_key': record.machineKey,
          'kind': record.kind,
          'status': record.status,
          'capabilities': record.capabilities,
        },
      );

  /// Maps an Agent registry record into Notion properties (g6), including the
  /// Environment binding by immutable ENV id.
  NotionSyncEntity fromAgent(AgentRecord record) => NotionSyncEntity(
    canonicalId: record.id,
    type: 'agent',
    properties: {
      'canonical_id': record.id,
      'type': 'agent',
      'title': record.name,
      'kind': record.kind,
      'status': record.status,
      'relations': {'environment_id': record.environmentId},
    },
  );
}

/// Raised when an inbound Notion edit cannot be reconciled into Git canonical
/// without silently overwriting authoritative state. Conflicts are always
/// explicit — the reconciler never blind-writes an authoritative field.
class NotionReconcileConflict implements Exception {
  const NotionReconcileConflict(this.canonicalId, this.reason);
  final String canonicalId;
  final String reason;
  @override
  String toString() => 'NotionReconcileConflict($canonicalId): $reason';
}

/// The outcome of reconciling one inbound Notion change into Git canonical.
class NotionReconcileResult {
  const NotionReconcileResult({
    required this.canonicalId,
    required this.type,
    required this.action,
  });
  final String canonicalId;
  final String type;

  /// `updated`, `archived`, or `mirror` (no authoritative change applied).
  final String action;
}

/// Writes inbound Notion edits back into the Git-canonical store (g6).
///
/// Notion is never canonical; this reconciler is the single inbound path that
/// validates and merges a [NotionInboundChange] into Git through the same Core
/// services (and therefore the same contract validators) the UI uses. Ids and
/// relations round-trip intact because edits go through the typed services that
/// preserve them; authoritative fields (a Match review state, an unknown
/// entity) raise an explicit [NotionReconcileConflict] instead of a silent
/// overwrite.
class NotionCanonicalReconciler {
  NotionCanonicalReconciler(this.workspace)
    : _repository = CanonicalRepository(workspace),
      _entities = EntityService(workspace),
      _tasks = TaskRepository(workspace),
      _environments = EnvironmentService(workspace),
      _agents = AgentRegistryService(workspace),
      _matches = MatchService(workspace);

  final Workspace workspace;
  final CanonicalRepository _repository;
  final EntityService _entities;
  final TaskRepository _tasks;
  final EnvironmentService _environments;
  final AgentRegistryService _agents;
  final MatchService _matches;

  static const _graphKinds = {
    'domain': EntityKind.domain,
    'milestone': EntityKind.milestone,
    'objective': EntityKind.objective,
    'knowledge': EntityKind.knowledge,
    'reference': EntityKind.reference,
  };

  NotionReconcileResult apply(NotionInboundChange change) {
    final type = change.type;
    if (_graphKinds.containsKey(type)) return _applyGraph(change);
    if (type == 'task') return _applyTask(change);
    if (type == 'environment') return _applyEnvironment(change);
    if (type == 'agent') return _applyAgent(change);
    if (type == 'match') return _applyMatch(change);
    throw NotionReconcileConflict(
      change.canonicalId,
      'unknown inbound type "$type"',
    );
  }

  NotionReconcileResult _applyGraph(NotionInboundChange change) {
    final kind = _graphKinds[change.type]!;
    final entity = _repository.get(kind, change.canonicalId);
    if (entity == null) {
      throw NotionReconcileConflict(
        change.canonicalId,
        'no canonical ${change.type} to reconcile',
      );
    }
    if (change.archived) {
      _entities.archive(entity);
      return NotionReconcileResult(
        canonicalId: change.canonicalId,
        type: change.type,
        action: 'archived',
      );
    }
    final title = change.properties['title'];
    final status = change.properties['status'];
    // Updating through EntityService preserves the id, relations, scope and
    // origin/provenance fields — only the human-facing title/status change.
    _entities.update(
      entity,
      title: title is String && title.trim().isNotEmpty ? title : null,
      status: status is String && status.trim().isNotEmpty ? status : null,
    );
    return NotionReconcileResult(
      canonicalId: change.canonicalId,
      type: change.type,
      action: 'updated',
    );
  }

  NotionReconcileResult _applyTask(NotionInboundChange change) {
    final task = _tasks.get(change.canonicalId);
    if (task == null) {
      throw NotionReconcileConflict(
        change.canonicalId,
        'no canonical task to reconcile',
      );
    }
    final title = change.properties['title'];
    if (title is String && title.trim().isNotEmpty && title != task.title) {
      _tasks.update(task.copyWith(title: title.trim()));
    }
    return NotionReconcileResult(
      canonicalId: change.canonicalId,
      type: 'task',
      action: 'updated',
    );
  }

  NotionReconcileResult _applyEnvironment(NotionInboundChange change) {
    if (_environments.get(change.canonicalId) == null) {
      throw NotionReconcileConflict(
        change.canonicalId,
        'no canonical environment to reconcile',
      );
    }
    final alias = change.properties['title'];
    if (alias is String && alias.trim().isNotEmpty) {
      _environments.rename(change.canonicalId, alias);
    }
    final status = change.properties['status'];
    if (status is String && status.trim().isNotEmpty) {
      _environments.setStatus(change.canonicalId, status);
    }
    return NotionReconcileResult(
      canonicalId: change.canonicalId,
      type: 'environment',
      action: 'updated',
    );
  }

  NotionReconcileResult _applyAgent(NotionInboundChange change) {
    if (_agents.get(change.canonicalId) == null) {
      throw NotionReconcileConflict(
        change.canonicalId,
        'no canonical agent to reconcile',
      );
    }
    final name = change.properties['title'];
    if (name is String && name.trim().isNotEmpty) {
      _agents.rename(change.canonicalId, name);
    }
    final status = change.properties['status'];
    if (status is String && status.trim().isNotEmpty) {
      _agents.setStatus(change.canonicalId, status);
    }
    return NotionReconcileResult(
      canonicalId: change.canonicalId,
      type: 'agent',
      action: 'updated',
    );
  }

  NotionReconcileResult _applyMatch(NotionInboundChange change) {
    final match = _matches.get(change.canonicalId);
    if (match == null) {
      throw NotionReconcileConflict(
        change.canonicalId,
        'no canonical match to reconcile',
      );
    }
    // The review state is authoritative in Git and only mutates through the
    // audited MatchService transitions. A Notion edit that tries to change it
    // is an explicit conflict, never a silent overwrite.
    final incomingState = change.properties['review_state'];
    if (incomingState is String &&
        incomingState.isNotEmpty &&
        incomingState != match.reviewState) {
      throw NotionReconcileConflict(
        change.canonicalId,
        'review_state is authoritative in Git; refusing to overwrite '
        '${match.reviewState} with "$incomingState" from Notion',
      );
    }
    // Subject/target/relations are mirrored read-only; nothing to write.
    return NotionReconcileResult(
      canonicalId: change.canonicalId,
      type: 'match',
      action: 'mirror',
    );
  }
}
