import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

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
      home: WorkspaceScreen(workspaceOverride: workspaceOverride),
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
        Directory(
          '${(await getApplicationSupportDirectory()).path}/sample-workspace',
        );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
  });

  final WorkTask task;
  final String? message;
  final VoidCallback onStart;

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
        const SizedBox(height: 6),
        SelectableText(task.promptDraft),
        const SizedBox(height: 24),
        Text('Prompt Meta', style: Theme.of(context).textTheme.titleMedium),
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
        if (message != null) ...[const SizedBox(height: 16), Text(message!)],
      ],
    );
  }
}
