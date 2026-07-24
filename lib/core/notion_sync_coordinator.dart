import 'dart:async';
import 'dart:io';

import 'agent_registry_service.dart';
import 'canonical_repository.dart';
import 'environment_service.dart';
import 'notion_secret_store.dart';
import 'notion_sync_adapter.dart';
import 'task_repository.dart';
import 'workspace.dart';

enum NotionSyncPhase { idle, connecting, pushing, pulling, conflict, failed }

class NotionSyncStatus {
  const NotionSyncStatus(this.phase, {this.message});
  final NotionSyncPhase phase;
  final String? message;
}

class NotionSyncReport {
  const NotionSyncReport({
    required this.pushed,
    required this.pulled,
    this.commitHash,
  });
  final int pushed;
  final int pulled;
  final String? commitHash;
}

/// Single explicit-sync entry point used by Flutter.
///
/// It deliberately has no timer/background loop. Inbound state is acknowledged
/// only after the injected Git commit succeeds.
class NotionSyncCoordinator {
  NotionSyncCoordinator({
    required this.workspace,
    required this.client,
    required this.secretStore,
    required this.configStore,
    required this.commitCanonical,
  });

  final Workspace workspace;
  final NotionClient client;
  final NotionSecretStore secretStore;
  final NotionLocalConfigStore configStore;
  final Future<String> Function() commitCanonical;

  final StreamController<NotionSyncStatus> _statuses =
      StreamController<NotionSyncStatus>.broadcast();

  Stream<NotionSyncStatus> watchStatus() => _statuses.stream;

  Future<void> dispose() => _statuses.close();

  Future<NotionSyncStatus> connect(NotionLocalConfig config) async {
    _statuses.add(const NotionSyncStatus(NotionSyncPhase.connecting));
    try {
      final token = await secretStore.readToken(config.secretRef);
      if (token == null || token.trim().isEmpty) {
        throw const NotionSyncException(
          'Notion credential is unavailable in the OS secure store.',
        );
      }
      await client.verifyConnection(token);
      configStore.save(config);
      const status = NotionSyncStatus(NotionSyncPhase.idle);
      _statuses.add(status);
      return status;
    } on Object catch (error) {
      _statuses.add(
        NotionSyncStatus(NotionSyncPhase.failed, message: '$error'),
      );
      rethrow;
    }
  }

  Future<NotionSyncReport> pushCanonical() async {
    _statuses.add(const NotionSyncStatus(NotionSyncPhase.pushing));
    try {
      final adapter = _adapter();
      final mapper = const NotionEntityMapper();
      final entities = CanonicalRepository(
        workspace,
      ).list().where((entity) => adapter.databases.supports(entity.kind.type));
      var pushed = 0;
      for (final entity in entities) {
        await adapter.push(mapper.fromCanonical(entity));
        pushed++;
      }
      for (final task in TaskRepository(workspace).list()) {
        if (!adapter.databases.supports('task')) break;
        await adapter.push(mapper.fromTask(task));
        pushed++;
      }
      for (final environment in EnvironmentService(workspace).list()) {
        if (!adapter.databases.supports('environment')) break;
        await adapter.push(mapper.fromEnvironment(environment));
        pushed++;
      }
      for (final agent in AgentRegistryService(workspace).list()) {
        if (!adapter.databases.supports('agent')) break;
        await adapter.push(mapper.fromAgent(agent));
        pushed++;
      }
      _save(adapter);
      _statuses.add(const NotionSyncStatus(NotionSyncPhase.idle));
      return NotionSyncReport(pushed: pushed, pulled: 0);
    } on NotionConflict catch (error) {
      _statuses.add(
        NotionSyncStatus(NotionSyncPhase.conflict, message: '$error'),
      );
      rethrow;
    } on Object catch (error) {
      _statuses.add(
        NotionSyncStatus(NotionSyncPhase.failed, message: '$error'),
      );
      rethrow;
    }
  }

  Future<NotionSyncReport> pullAndCommit() async {
    _statuses.add(const NotionSyncStatus(NotionSyncPhase.pulling));
    try {
      final adapter = _adapter();
      final pull = await adapter.pull();
      String? commitHash;
      if (pull.changes.isNotEmpty) {
        commitHash = await adapter.reconcileAndAcknowledge(
          pull,
          reconciler: NotionCanonicalReconciler(workspace),
          commit: commitCanonical,
        );
      } else {
        // Own echoes contain no canonical edit and require no Git commit, but
        // may safely advance their projection cursor.
        adapter.acknowledge(pull);
      }
      _save(adapter);
      _statuses.add(const NotionSyncStatus(NotionSyncPhase.idle));
      return NotionSyncReport(
        pushed: 0,
        pulled: pull.changes.length,
        commitHash: commitHash,
      );
    } on NotionConflict catch (error) {
      _statuses.add(
        NotionSyncStatus(NotionSyncPhase.conflict, message: '$error'),
      );
      rethrow;
    } on Object catch (error) {
      _statuses.add(
        NotionSyncStatus(NotionSyncPhase.failed, message: '$error'),
      );
      rethrow;
    }
  }

  /// Explicitly resolves a concurrent edit in favour of Git canonical.
  ///
  /// The ordinary push path must never overwrite a foreign edit. This separate
  /// method makes the user's reviewed disposition visible at the API boundary.
  Future<void> resolveKeepGit(String canonicalId) async {
    final adapter = _adapter();
    final mapper = const NotionEntityMapper();
    NotionSyncEntity? entity;
    CanonicalEntity? canonical;
    for (final candidate in CanonicalRepository(workspace).list()) {
      if (candidate.id == canonicalId) {
        canonical = candidate;
        break;
      }
    }
    if (canonical != null) {
      entity = mapper.fromCanonical(canonical);
    } else {
      final task = TaskRepository(workspace).get(canonicalId);
      if (task != null) entity = mapper.fromTask(task);
      final environment = EnvironmentService(workspace).get(canonicalId);
      if (environment != null) entity = mapper.fromEnvironment(environment);
      final agent = AgentRegistryService(workspace).get(canonicalId);
      if (agent != null) entity = mapper.fromAgent(agent);
    }
    if (entity == null) {
      throw NotionSyncException(
        'No Git canonical entity exists for $canonicalId.',
      );
    }
    await adapter.push(entity, overwriteRemote: true);
    _save(adapter);
    _statuses.add(const NotionSyncStatus(NotionSyncPhase.idle));
  }

  NotionSyncAdapter _adapter() {
    final config = configStore.load();
    if (config == null || !config.enabled) {
      throw const NotionSyncException('Notion sync is not configured.');
    }
    final store = NotionSyncStore(
      File('${workspace.local.path}/notion-sync.json'),
    );
    return NotionSyncAdapter(
      client: client,
      secretStore: secretStore,
      secretRef: config.secretRef,
      databases: NotionDatabaseMap(config.databases),
      state: store.loadOrCreate(),
    );
  }

  void _save(NotionSyncAdapter adapter) {
    NotionSyncStore(
      File('${workspace.local.path}/notion-sync.json'),
    ).save(adapter.state);
  }
}
