import 'dart:io';

import 'package:flutter/material.dart';

import 'core/worklog_core.dart';

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff315c53),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: workspaceOverride == null
          ? const SetupScreen()
          : WorkspaceScreen(workspaceOverride: workspaceOverride),
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
      return WorkspaceScreen(workspaceOverride: workspace);
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
      _message = 'SQLite projection rebuilt from Git-tracked YAML.';
    });
  }

  void _requestStart() {
    final task = _selected;
    if (task == null) return;
    try {
      final operationId = newId('OP');
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
        operationId: newId('OP'),
        runId: command == ControlCommand.start ? null : runId,
      );
      setState(() => _message = '${command.name} requested · $result');
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _root == null ? null : _createTask,
        icon: const Icon(Icons.add),
        label: const Text('Task'),
      ),
      appBar: AppBar(
        title: const Text('Under Claw Work'),
        actions: [
          IconButton(
            tooltip: 'Rebuild local projection',
            onPressed: _root == null ? null : _refresh,
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: _root == null
          ? const Center(child: CircularProgressIndicator())
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
                          onStart: _requestStart,
                          onEditDraft: () => _editPrompt(meta: false),
                          onEditMeta: () => _editPrompt(meta: true),
                          onApproveMeta: _approveMeta,
                          onControl: _requestControl,
                        ),
                ),
              ],
            ),
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
    required this.onStart,
    required this.onEditDraft,
    required this.onEditMeta,
    required this.onApproveMeta,
    required this.onControl,
  });

  final WorkTask task;
  final String? message;
  final VoidCallback onStart;
  final VoidCallback onEditDraft;
  final VoidCallback onEditMeta;
  final VoidCallback onApproveMeta;
  final ValueChanged<ControlCommand> onControl;

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
        if (message != null) ...[const SizedBox(height: 16), Text(message!)],
      ],
    );
  }
}
