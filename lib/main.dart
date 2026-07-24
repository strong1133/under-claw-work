import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'core/worklog_core.dart';
import 'ui/agent_screen.dart';
import 'ui/app_theme.dart';
import 'ui/environment_screen.dart';
import 'ui/match_screen.dart';
import 'ui/memory_screen.dart';
import 'ui/notion_screens.dart';
import 'ui/notion_sync_port.dart';
import 'ui/workspace_shell.dart';

void main() {
  runApp(const UnderClawWorkApp());
}

class UnderClawWorkApp extends StatelessWidget {
  const UnderClawWorkApp({super.key, this.workspaceOverride});

  final Directory? workspaceOverride;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Under Claw Work',
      // Orca/Warp-inspired dark shell by default, with a light counterpart; both
      // are pure functions of the token layer (see lib/ui/app_theme.dart).
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: workspaceOverride == null
          ? const SetupScreen()
          : WorkspaceComposition(workspaceRoot: workspaceOverride!),
    );
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _path = TextEditingController();
  final _environment = TextEditingController();
  final _remote = TextEditingController();
  Directory? _workspace;
  String? _error;
  bool _running = false;

  @override
  void dispose() {
    _path.dispose();
    _environment.dispose();
    _remote.dispose();
    super.dispose();
  }

  Future<void> _setup() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final remote = _remote.text.trim();
      final result = await SetupService().setup(
        SetupRequest(
          localPath: _path.text.trim(),
          environmentName: _environment.text.trim(),
          privateRemote: remote.isEmpty ? null : Uri.parse(remote),
        ),
      );
      if (mounted) setState(() => _workspace = result.workspace.root);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final workspace = _workspace;
    if (workspace != null) {
      return WorkspaceComposition(workspaceRoot: workspace);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Under Claw Work setup')),
      body: Center(
        child: SizedBox(
          width: 560,
          child: ListView(
            padding: const EdgeInsets.all(32),
            shrinkWrap: true,
            children: [
              Text(
                'Connect your private Git workspace',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _path,
                decoration: const InputDecoration(
                  labelText: 'Local Git path',
                  hintText: '/path/to/workspace',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _environment,
                decoration: const InputDecoration(
                  labelText: 'Environment name',
                  hintText: 'My desktop',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _remote,
                decoration: const InputDecoration(
                  labelText: 'Private remote (optional)',
                  helperText:
                      'Credentials must come from your Git credential helper.',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _running ? null : _setup,
                icon: const Icon(Icons.folder_open),
                label: Text(_running ? 'Connecting…' : 'Connect workspace'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WorkspaceComposition extends StatefulWidget {
  const WorkspaceComposition({super.key, required this.workspaceRoot});

  final Directory workspaceRoot;

  @override
  State<WorkspaceComposition> createState() => _WorkspaceCompositionState();
}

class _WorkspaceCompositionState extends State<WorkspaceComposition> {
  late final http.Client _httpClient;
  late final PlatformNotionSecretStore _secretStore;
  late final NotionSyncCoordinator _coordinator;
  late final _NotionControllerAdapter _notion;

  @override
  void initState() {
    super.initState();
    final workspace = Workspace(widget.workspaceRoot);
    _httpClient = http.Client();
    _secretStore = const PlatformNotionSecretStore();
    _coordinator = NotionSyncCoordinator(
      workspace: workspace,
      client: NotionApiClient(httpClient: _httpClient),
      secretStore: _secretStore,
      configStore: NotionLocalConfigStore(
        File('${workspace.local.path}/notion-config.json'),
      ),
      commitCanonical: () => GitSyncService(
        workspace,
      ).commitCanonical(message: 'worklog: reconcile Notion mirror'),
    );
    _notion = _NotionControllerAdapter(
      coordinator: _coordinator,
      secretStore: _secretStore,
    );
  }

  @override
  void dispose() {
    _notion.dispose();
    _coordinator.dispose();
    _httpClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UnifiedWorkspaceShell(
    destinations: [
      WorkspaceDestination(
        label: 'Work',
        icon: Icons.account_tree_outlined,
        child: WorkspaceScreen(workspaceOverride: widget.workspaceRoot),
      ),
      WorkspaceDestination(
        label: 'Environments',
        icon: Icons.dns_outlined,
        child: EnvironmentManagementScreen(workspaceRoot: widget.workspaceRoot),
      ),
      WorkspaceDestination(
        label: 'Agents',
        icon: Icons.smart_toy_outlined,
        child: AgentManagementScreen(workspaceRoot: widget.workspaceRoot),
      ),
      WorkspaceDestination(
        label: 'Matches',
        icon: Icons.rule_outlined,
        child: MatchReviewScreen(workspaceRoot: widget.workspaceRoot),
      ),
      WorkspaceDestination(
        label: 'Memory',
        icon: Icons.history_edu_outlined,
        child: MemoryRecallScreen(workspaceRoot: widget.workspaceRoot),
      ),
      WorkspaceDestination(
        label: 'Notion setup',
        icon: Icons.settings_outlined,
        child: NotionSetupView(controller: _notion),
      ),
      WorkspaceDestination(
        label: 'Notion sync',
        icon: Icons.sync_outlined,
        child: NotionSyncView(controller: _notion),
      ),
      WorkspaceDestination(
        label: 'Conflicts',
        icon: Icons.merge_type,
        child: NotionConflictViewScreen(controller: _notion),
      ),
    ],
  );
}

class _NotionControllerAdapter implements NotionUiController {
  _NotionControllerAdapter({
    required this.coordinator,
    required this.secretStore,
  }) {
    _subscription = coordinator.watchStatus().listen(_onCoreStatus);
  }

  final NotionSyncCoordinator coordinator;
  final NotionSecretStore secretStore;
  final ValueNotifier<NotionSyncViewState> _state = ValueNotifier(
    const NotionSyncViewState(),
  );
  late final StreamSubscription<NotionSyncStatus> _subscription;

  @override
  ValueListenable<NotionSyncViewState> get state => _state;

  @override
  Future<void> connect(NotionConnectionDraft draft) async {
    final ref = NotionSecretRef(draft.secretLocator);
    _state.value = const NotionSyncViewState(
      status: NotionConnectionStatus.connecting,
      message: 'Testing Notion connection…',
    );
    try {
      await secretStore.writeToken(ref, draft.token);
      await coordinator.connect(
        NotionLocalConfig(
          enabled: true,
          secretRef: ref,
          databases: draft.databaseIds,
        ),
      );
      _state.value = const NotionSyncViewState(
        status: NotionConnectionStatus.connected,
        message: 'Notion connection is ready.',
      );
    } on Object catch (error) {
      _state.value = NotionSyncViewState(
        status: NotionConnectionStatus.error,
        message: '$error',
      );
      rethrow;
    }
  }

  @override
  Future<void> syncNow() async {
    _state.value = NotionSyncViewState(
      status: NotionConnectionStatus.syncing,
      message: 'Synchronizing Git canonical data with Notion…',
      lastSyncedAt: _state.value.lastSyncedAt,
    );
    try {
      final pushed = await coordinator.pushCanonical();
      final pulled = await coordinator.pullAndCommit();
      _state.value = NotionSyncViewState(
        status: NotionConnectionStatus.connected,
        message: 'Notion mirror synchronized.',
        lastSyncedAt: DateTime.now(),
        pushed: pushed.pushed,
        pulled: pulled.pulled,
      );
    } on NotionConflict catch (error) {
      final snapshot =
          error.snapshot ?? coordinator.conflict(error.canonicalId);
      final conflict = snapshot == null ? null : _toConflictView(snapshot);
      _state.value = NotionSyncViewState(
        status: NotionConnectionStatus.error,
        message: 'A Notion conflict requires review.',
        lastSyncedAt: _state.value.lastSyncedAt,
        pushed: _state.value.pushed,
        pulled: _state.value.pulled,
        conflicts: conflict == null
            ? _state.value.conflicts
            : _replaceConflict(_state.value.conflicts, conflict),
      );
    } on Object catch (error) {
      _state.value = NotionSyncViewState(
        status: NotionConnectionStatus.error,
        message: '$error',
      );
      rethrow;
    }
  }

  @override
  Future<void> resolveConflict(
    String conflictId,
    NotionConflictChoice choice,
  ) async {
    final index = _state.value.conflicts.indexWhere(
      (conflict) => conflict.conflictId == conflictId,
    );
    if (index < 0) return;
    final conflict = _state.value.conflicts[index];
    if (choice == NotionConflictChoice.postpone) {
      _updateConflict(
        conflictId,
        conflict.copyWith(
          status: NotionConflictCardStatus.postponed,
          clearError: true,
        ),
      );
      return;
    }
    _updateConflict(
      conflictId,
      conflict.copyWith(
        status: NotionConflictCardStatus.resolving,
        clearError: true,
      ),
    );
    try {
      if (choice == NotionConflictChoice.keepGit) {
        await coordinator.resolveKeepGit(conflict.canonicalId);
      } else {
        await coordinator.resolveApplyNotion(conflict.canonicalId);
      }
      final remaining = _state.value.conflicts
          .where((item) => item.conflictId != conflictId)
          .toList(growable: false);
      _state.value = _state.value.copyWith(
        status: remaining.isEmpty
            ? NotionConnectionStatus.connected
            : NotionConnectionStatus.error,
        message: 'Conflict resolution completed for ${conflict.canonicalId}.',
        lastSyncedAt: DateTime.now(),
        conflicts: remaining,
      );
    } on Object catch (error) {
      _updateConflict(
        conflictId,
        conflict.copyWith(
          status: NotionConflictCardStatus.failed,
          errorMessage: '$error',
        ),
      );
    }
  }

  static NotionConflictView _toConflictView(
    NotionConflictSnapshot snapshot,
  ) => NotionConflictView(
    conflictId: snapshot.conflictId,
    canonicalId: snapshot.canonicalId,
    type: snapshot.type,
    remoteRevision: snapshot.remoteRevision,
    gitProperties: snapshot.gitProperties,
    notionProperties: snapshot.notionProperties,
    authoritativeFields: switch (snapshot.type) {
      'environment' => const {'canonical_id', 'type', 'machine_key', 'kind'},
      'agent' => const {'canonical_id', 'type', 'kind', 'relations'},
      'match' => const {'canonical_id', 'type', 'review_state', 'relations'},
      _ => const {'canonical_id', 'type', 'relations'},
    },
  );

  static List<NotionConflictView> _replaceConflict(
    List<NotionConflictView> conflicts,
    NotionConflictView replacement,
  ) => [
    for (final conflict in conflicts)
      if (conflict.canonicalId != replacement.canonicalId) conflict,
    replacement,
  ];

  void _updateConflict(String conflictId, NotionConflictView replacement) {
    _state.value = _state.value.copyWith(
      conflicts: [
        for (final conflict in _state.value.conflicts)
          if (conflict.conflictId == conflictId) replacement else conflict,
      ],
    );
  }

  void _onCoreStatus(NotionSyncStatus status) {
    if (status.phase == NotionSyncPhase.conflict) return;
    final mapped = switch (status.phase) {
      NotionSyncPhase.connecting => NotionConnectionStatus.connecting,
      NotionSyncPhase.pushing ||
      NotionSyncPhase.pulling => NotionConnectionStatus.syncing,
      NotionSyncPhase.failed => NotionConnectionStatus.error,
      _ => NotionConnectionStatus.connected,
    };
    _state.value = NotionSyncViewState(
      status: mapped,
      message: status.message ?? _state.value.message,
      lastSyncedAt: _state.value.lastSyncedAt,
      pushed: _state.value.pushed,
      pulled: _state.value.pulled,
      conflicts: _state.value.conflicts,
    );
  }

  void dispose() {
    _subscription.cancel();
    _state.dispose();
  }
}

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, this.workspaceOverride});

  final Directory? workspaceOverride;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  Directory? _root;
  ProjectionStore? _projection;
  List<WorkTask> _tasks = const [];
  WorkTask? _selected;
  EntityKind _viewKind = EntityKind.task;
  List<CanonicalEntity> _entities = const [];
  CanonicalEntity? _selectedEntity;
  String? _message;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final root =
        widget.workspaceOverride ??
        (throw StateError('Workspace setup must complete before opening.'));
    final projection = ProjectionStore(Workspace(root));
    final tasks = projection.rebuild();
    if (!mounted) return;
    setState(() {
      _root = root;
      _projection = projection;
      _tasks = tasks;
      _selected = tasks.firstOrNull;
      _reloadEntities();
    });
  }

  @override
  void dispose() {
    _projection?.dispose();
    super.dispose();
  }

  void _refresh() {
    final tasks = _projection!.rebuild();
    setState(() {
      _tasks = tasks;
      _selected = tasks.where((task) => task.id == _selected?.id).firstOrNull;
      _reloadEntities();
      _message = 'SQLite projection rebuilt from Git-tracked YAML.';
    });
  }

  void _reloadEntities() {
    if (_root == null || _viewKind == EntityKind.task) return;
    _entities = CanonicalRepository(Workspace(_root!))
        .list(_viewKind)
        .where((entity) => entity.data['status'] != 'archived')
        .toList();
    _selectedEntity =
        _entities.where((item) => item.id == _selectedEntity?.id).firstOrNull ??
        _entities.firstOrNull;
  }

  void _selectView(EntityKind kind) {
    setState(() {
      _viewKind = kind;
      _reloadEntities();
    });
  }

  Future<void> _createEntity() async {
    final title = TextEditingController();
    final body = TextEditingController();
    final domainId = TextEditingController();
    final milestoneId = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Create ${_viewKind.type}'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              if (_viewKind != EntityKind.domain)
                TextField(
                  controller: domainId,
                  decoration: const InputDecoration(labelText: 'Domain ID'),
                ),
              if (_viewKind != EntityKind.domain)
                TextField(
                  controller: milestoneId,
                  decoration: const InputDecoration(
                    labelText: 'Milestone ID (optional)',
                  ),
                ),
              TextField(
                controller: body,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Description / AI context',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      final created = EntityService(Workspace(_root!)).create(
        kind: _viewKind,
        title: title.text,
        body: body.text,
        domainId: domainId.text.trim().isEmpty ? null : domainId.text.trim(),
        milestoneId: milestoneId.text.trim().isEmpty
            ? null
            : milestoneId.text.trim(),
      );
      _projection!.rebuild();
      setState(() {
        _reloadEntities();
        _selectedEntity = created;
        _message = '${created.kind.type} created · ${created.id}';
      });
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  Future<void> _editEntity(CanonicalEntity entity) async {
    final title = TextEditingController(
      text: (entity.data['title'] ?? entity.data['name']).toString(),
    );
    final body = TextEditingController(text: entity.body);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit ${entity.kind.type}'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: body,
                minLines: 5,
                maxLines: 12,
                decoration: const InputDecoration(labelText: 'AI context'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final updated = EntityService(
      Workspace(_root!),
    ).update(entity, title: title.text, body: body.text);
    _projection!.rebuild();
    setState(() {
      _reloadEntities();
      _selectedEntity = updated;
      _message = '${updated.id} saved';
    });
  }

  void _archiveEntity(CanonicalEntity entity) {
    EntityService(Workspace(_root!)).archive(entity);
    _projection!.rebuild();
    setState(() {
      _reloadEntities();
      _message = '${entity.id} archived';
    });
  }

  void _requestStart() {
    final task = _selected;
    if (task == null) return;
    try {
      final operationId = newId('OPR');
      final runId = ControlService(
        Workspace(_root!),
        _projection!,
      ).requestStart(task, operationId);
      setState(() => _message = 'Start requested · $runId');
    } on StateError catch (error) {
      setState(() => _message = error.message.toString());
    }
  }

  Future<void> _createTask() async {
    final domain = TextEditingController();
    final milestone = TextEditingController();
    final title = TextEditingController();
    final environment = TextEditingController(text: 'ENV-local');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Task'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: domain,
                decoration: const InputDecoration(labelText: 'Domain ID'),
              ),
              TextField(
                controller: milestone,
                decoration: const InputDecoration(labelText: 'Milestone ID'),
              ),
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: environment,
                decoration: const InputDecoration(labelText: 'Environment ID'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      final task = TaskRepository(Workspace(_root!)).create(
        WorkTask(
          id: newId('TSK'),
          domainId: domain.text.trim(),
          milestoneId: milestone.text.trim(),
          title: title.text.trim(),
          status: TaskStatus.draft,
          promptDraft: '',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: environment.text.trim(),
        ),
      );
      _refresh();
      setState(() => _selected = task);
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  Future<void> _editPrompt({required bool meta}) async {
    final task = _selected;
    if (task == null) return;
    final controller = TextEditingController(
      text: meta ? task.promptMeta : task.promptDraft,
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(meta ? 'Edit Meta Prompt' : 'Edit Prompt Draft'),
        content: SizedBox(
          width: 620,
          child: TextField(controller: controller, minLines: 8, maxLines: 18),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final repository = TaskRepository(Workspace(_root!));
    final updated = meta
        ? repository.saveMeta(task, controller.text)
        : repository.saveDraft(task, controller.text);
    _refresh();
    setState(() => _selected = updated);
  }

  void _approveMeta() {
    final task = _selected;
    if (task == null) return;
    try {
      final updated = TaskRepository(
        Workspace(_root!),
      ).approveMeta(task).copyWith(status: TaskStatus.ready);
      TaskRepository(Workspace(_root!)).update(updated);
      _refresh();
      setState(() => _selected = updated);
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  void _requestControl(ControlCommand command) {
    final task = _selected;
    if (task == null) return;
    try {
      final runs = _projection!.open().select(
        'SELECT id FROM runs WHERE task_id = ? ORDER BY rowid DESC LIMIT 1',
        [task.id],
      );
      final runId = runs.isEmpty ? null : runs.single['id'] as String;
      final result = ControlService(Workspace(_root!), _projection!).request(
        task,
        command,
        operationId: newId('OPR'),
        runId: command == ControlCommand.start ? null : runId,
      );
      setState(() => _message = '${command.name} requested · $result');
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  void _withdrawControl(String requestId) {
    try {
      ControlService(Workspace(_root!), _projection!).withdraw(requestId);
      setState(() => _message = 'Control request withdrawn.');
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  List<TaskCandidate> _taskCandidates(WorkTask task) =>
      TaskCandidateService(Workspace(_root!))
          .list()
          .where((candidate) => candidate.parentTaskId == task.id)
          .toList()
          .reversed
          .toList();

  void _disposeCandidate(String id, bool accept) {
    try {
      final service = TaskCandidateService(Workspace(_root!));
      if (accept) {
        final task = service.accept(id);
        _refresh();
        setState(() {
          _selected = task;
          _message = 'Candidate accepted as ${task.id}.';
        });
      } else {
        service.reject(id);
        setState(() => _message = 'Candidate rejected.');
      }
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  Future<void> _editTaskPolicy() async {
    final task = _selected;
    if (task == null) return;
    var derive = task.autoDeriveTasks;
    var followup = task.autoFollowupTasks;
    final depth = TextEditingController(text: '${task.maxGenerationDepth}');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Automatic Task policy'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('Generate derived Tasks'),
                value: derive,
                onChanged: (value) => setDialogState(() => derive = value),
              ),
              SwitchListTile(
                title: const Text('Generate follow-up Tasks'),
                value: followup,
                onChanged: (value) => setDialogState(() => followup = value),
              ),
              TextField(
                controller: depth,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Maximum generation depth',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    try {
      final updated = TaskRepository(Workspace(_root!)).update(
        task.copyWith(
          autoDeriveTasks: derive,
          autoFollowupTasks: followup,
          maxGenerationDepth: int.parse(depth.text),
        ),
      );
      _refresh();
      setState(() {
        _selected = updated;
        _message = 'Automatic Task policy saved.';
      });
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  List<CanonicalEntity> _controlRequests(WorkTask task) =>
      CanonicalRepository(Workspace(_root!))
          .list(EntityKind.controlRequest)
          .where((request) => request.data['task_id'] == task.id)
          .toList()
          .reversed
          .toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _root == null
            ? null
            : _viewKind == EntityKind.task
            ? _createTask
            : _createEntity,
        icon: const Icon(Icons.add),
        label: Text(_viewKind == EntityKind.task ? 'Task' : _viewKind.type),
      ),
      appBar: AppBar(
        title: const Text('Under Claw Work'),
        actions: [
          PopupMenuButton<EntityKind>(
            key: const Key('workspace-area-menu'),
            tooltip: 'Choose workspace area',
            initialValue: _viewKind,
            onSelected: _selectView,
            itemBuilder: (context) => [
              for (final kind in const [
                EntityKind.domain,
                EntityKind.milestone,
                EntityKind.objective,
                EntityKind.task,
                EntityKind.knowledge,
                EntityKind.reference,
              ])
                PopupMenuItem(value: kind, child: Text(kind.type)),
            ],
          ),
          IconButton(
            tooltip: 'Manage environments',
            onPressed: _root == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          EnvironmentManagementScreen(workspaceRoot: _root!),
                    ),
                  ),
            icon: const Icon(Icons.dns_outlined),
          ),
          IconButton(
            tooltip: 'Manage agents',
            onPressed: _root == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          AgentManagementScreen(workspaceRoot: _root!),
                    ),
                  ),
            icon: const Icon(Icons.smart_toy_outlined),
          ),
          IconButton(
            tooltip: 'Review matches',
            onPressed: _root == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MatchReviewScreen(workspaceRoot: _root!),
                    ),
                  ),
            icon: const Icon(Icons.rule_outlined),
          ),
          IconButton(
            tooltip: 'Recall memory',
            onPressed: _root == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MemoryRecallScreen(workspaceRoot: _root!),
                    ),
                  ),
            icon: const Icon(Icons.history_edu_outlined),
          ),
          IconButton(
            tooltip: 'Rebuild local projection',
            onPressed: _root == null ? null : _refresh,
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: _root == null
          ? const Center(child: CircularProgressIndicator())
          : _viewKind != EntityKind.task
          ? Row(
              children: [
                SizedBox(
                  width: 320,
                  child: _GraphEntityList(
                    entities: _entities,
                    selected: _selectedEntity,
                    onSelected: (entity) =>
                        setState(() => _selectedEntity = entity),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _selectedEntity == null
                      ? Center(child: Text('No ${_viewKind.type} yet'))
                      : _GraphEntityDetail(
                          entity: _selectedEntity!,
                          message: _message,
                          onEdit: () => _editEntity(_selectedEntity!),
                          onArchive: () => _archiveEntity(_selectedEntity!),
                        ),
                ),
              ],
            )
          : Row(
              children: [
                SizedBox(
                  width: 320,
                  child: _TaskList(
                    tasks: _tasks,
                    selected: _selected,
                    onSelected: (task) => setState(() => _selected = task),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _selected == null
                      ? _EmptyWorkspace(path: _root!.path)
                      : _TaskDetail(
                          task: _selected!,
                          message: _message,
                          candidates: _taskCandidates(_selected!),
                          controlRequests: _controlRequests(_selected!),
                          dispositionFor: (requestId) => ControlService(
                            Workspace(_root!),
                            _projection!,
                          ).dispositionFor(requestId),
                          onStart: _requestStart,
                          onEditDraft: () => _editPrompt(meta: false),
                          onEditMeta: () => _editPrompt(meta: true),
                          onApproveMeta: _approveMeta,
                          onControl: _requestControl,
                          onWithdraw: _withdrawControl,
                          onCandidateDisposition: _disposeCandidate,
                          onEditPolicy: _editTaskPolicy,
                        ),
                ),
              ],
            ),
    );
  }
}

class _GraphEntityList extends StatelessWidget {
  const _GraphEntityList({
    required this.entities,
    required this.selected,
    required this.onSelected,
  });

  final List<CanonicalEntity> entities;
  final CanonicalEntity? selected;
  final ValueChanged<CanonicalEntity> onSelected;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        for (final entity in entities)
          ListTile(
            selected: selected?.id == entity.id,
            title: Text(
              (entity.data['title'] ?? entity.data['name'] ?? entity.id)
                  .toString(),
            ),
            subtitle: Text(entity.id),
            onTap: () => onSelected(entity),
          ),
      ],
    );
  }
}

class _GraphEntityDetail extends StatelessWidget {
  const _GraphEntityDetail({
    required this.entity,
    required this.message,
    required this.onEdit,
    required this.onArchive,
  });

  final CanonicalEntity entity;
  final String? message;
  final VoidCallback onEdit;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        Text(
          (entity.data['title'] ?? entity.data['name'] ?? entity.id).toString(),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text('${entity.kind.type} · ${entity.id}'),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            Chip(label: Text((entity.data['status'] ?? 'active').toString())),
            if (entity.data['priority'] != null)
              Chip(label: Text('priority: ${entity.data['priority']}')),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          entity.body.isEmpty ? 'No AI context yet.' : entity.body,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              onPressed: onEdit,
              icon: const Icon(Icons.edit),
              label: const Text('Edit'),
            ),
            OutlinedButton.icon(
              onPressed: onArchive,
              icon: const Icon(Icons.archive),
              label: const Text('Archive'),
            ),
          ],
        ),
        if (message != null) ...[const SizedBox(height: 16), Text(message!)],
      ],
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({
    required this.tasks,
    required this.selected,
    required this.onSelected,
  });

  final List<WorkTask> tasks;
  final WorkTask? selected;
  final ValueChanged<WorkTask> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Tasks',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: tasks.length,
            itemBuilder: (context, index) {
              final task = tasks[index];
              return ListTile(
                selected: selected?.id == task.id,
                title: Text(task.title),
                subtitle: Text('${task.id} · ${task.status.name}'),
                leading: Icon(
                  task.isMetaCurrent ? Icons.check_circle : Icons.warning_amber,
                ),
                onTap: () => onSelected(task),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EmptyWorkspace extends StatelessWidget {
  const _EmptyWorkspace({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_open, size: 54),
            const SizedBox(height: 16),
            Text('No tasks yet', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'Add a YAML task under workdb/tasks, then rebuild the projection.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            SelectableText(path),
          ],
        ),
      ),
    );
  }
}

class _TaskDetail extends StatelessWidget {
  const _TaskDetail({
    required this.task,
    required this.message,
    required this.candidates,
    required this.controlRequests,
    required this.dispositionFor,
    required this.onStart,
    required this.onEditDraft,
    required this.onEditMeta,
    required this.onApproveMeta,
    required this.onControl,
    required this.onWithdraw,
    required this.onCandidateDisposition,
    required this.onEditPolicy,
  });

  final WorkTask task;
  final String? message;
  final List<TaskCandidate> candidates;
  final List<CanonicalEntity> controlRequests;
  final CanonicalEntity? Function(String requestId) dispositionFor;
  final VoidCallback onStart;
  final VoidCallback onEditDraft;
  final VoidCallback onEditMeta;
  final VoidCallback onApproveMeta;
  final ValueChanged<ControlCommand> onControl;
  final ValueChanged<String> onWithdraw;
  final void Function(String id, bool accept) onCandidateDisposition;
  final VoidCallback onEditPolicy;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        Text(task.title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text('${task.domainId} / ${task.milestoneId} / ${task.id}'),
        const SizedBox(height: 24),
        Wrap(
          spacing: 8,
          children: [
            Chip(label: Text(task.status.name)),
            Chip(label: Text('target: ${task.targetEnvironment}')),
            Chip(
              label: Text(
                'derived: ${task.autoDeriveTasks ? "auto" : "manual"}',
              ),
            ),
            Chip(
              label: Text(
                'follow-up: ${task.autoFollowupTasks ? "auto" : "manual"}',
              ),
            ),
            Chip(
              label: Text(
                task.isMetaCurrent ? 'Meta approved' : 'Meta gate locked',
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Prompt Draft', style: Theme.of(context).textTheme.titleMedium),
        TextButton.icon(
          onPressed: onEditDraft,
          icon: const Icon(Icons.edit),
          label: const Text('Edit Draft'),
        ),
        const SizedBox(height: 6),
        SelectableText(task.promptDraft),
        const SizedBox(height: 24),
        Text('Prompt Meta', style: Theme.of(context).textTheme.titleMedium),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: onEditMeta,
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('Save generated Meta'),
            ),
            TextButton.icon(
              onPressed: task.approval == PromptApproval.pending
                  ? onApproveMeta
                  : null,
              icon: const Icon(Icons.approval),
              label: const Text('Approve Meta'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SelectableText(
          task.promptMeta.isEmpty ? 'Not generated' : task.promptMeta,
        ),
        const SizedBox(height: 28),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: task.isMetaCurrent ? onStart : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Request start'),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final command in [
              ControlCommand.pause,
              ControlCommand.resume,
              ControlCommand.cancel,
              ControlCommand.complete,
            ])
              OutlinedButton(
                onPressed: () => onControl(command),
                child: Text('Request ${command.name}'),
              ),
          ],
        ),
        const SizedBox(height: 28),
        Text(
          'Control activity',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (controlRequests.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No control requests.'),
          )
        else
          for (final request in controlRequests)
            Builder(
              builder: (context) {
                final disposition = dispositionFor(request.id);
                final state =
                    disposition?.data['disposition']?.toString() ?? 'pending';
                return ListTile(
                  key: Key('control-${request.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    state == 'pending' ? Icons.schedule : Icons.task_alt,
                  ),
                  title: Text('${request.data['command']} · $state'),
                  subtitle: Text(request.id),
                  trailing: state == 'pending'
                      ? TextButton(
                          onPressed: () => onWithdraw(request.id),
                          child: const Text('Withdraw request'),
                        )
                      : null,
                );
              },
            ),
        const SizedBox(height: 28),
        Text(
          'Generated Task candidates',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onEditPolicy,
            icon: const Icon(Icons.tune),
            label: const Text('Edit automatic Task policy'),
          ),
        ),
        if (candidates.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No generated candidates.'),
          )
        else
          for (final candidate in candidates)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(candidate.title),
              subtitle: Text(
                '${candidate.id} · ${candidate.disposition.name} · '
                'depth ${candidate.depth}',
              ),
              trailing: candidate.disposition == CandidateDisposition.pending
                  ? Wrap(
                      children: [
                        TextButton(
                          onPressed: () =>
                              onCandidateDisposition(candidate.id, false),
                          child: const Text('Reject'),
                        ),
                        FilledButton(
                          onPressed: () =>
                              onCandidateDisposition(candidate.id, true),
                          child: const Text('Accept'),
                        ),
                      ],
                    )
                  : null,
            ),
        if (message != null) ...[const SizedBox(height: 16), Text(message!)],
      ],
    );
  }
}
