import 'package:flutter/material.dart';

import '../core/worklog_core.dart';

class TaskConfigurationDraft {
  const TaskConfigurationDraft({
    required this.title,
    required this.promptDraft,
    required this.domainId,
    required this.milestoneId,
    required this.projectIds,
    required this.environmentIds,
    required this.modelSelectionKeys,
    required this.processingMode,
    required this.requestMeta,
    required this.autoDeriveTasks,
    required this.autoFollowupTasks,
    required this.autoAcceptGeneratedTasks,
    required this.maxGenerationDepth,
    required this.parentTaskId,
    required this.relatedTaskIds,
  });

  final String title;
  final String promptDraft;
  final String domainId;
  final String milestoneId;
  final List<String> projectIds;
  final List<String> environmentIds;
  final List<String> modelSelectionKeys;
  final TaskProcessingMode processingMode;
  final bool requestMeta;
  final bool autoDeriveTasks;
  final bool autoFollowupTasks;
  final bool autoAcceptGeneratedTasks;
  final int maxGenerationDepth;
  final String? parentTaskId;
  final List<String> relatedTaskIds;
}

class TaskConfigurationDialog extends StatefulWidget {
  const TaskConfigurationDialog({
    required this.workspace,
    this.task,
    super.key,
  });

  final Workspace workspace;
  final WorkTask? task;

  @override
  State<TaskConfigurationDialog> createState() =>
      _TaskConfigurationDialogState();
}

class _TaskConfigurationDialogState extends State<TaskConfigurationDialog> {
  late final TextEditingController _title;
  late final TextEditingController _draft;
  late final TextEditingController _depth;
  late final List<CanonicalEntity> _domains;
  late final List<CanonicalEntity> _milestones;
  late final List<CanonicalEntity> _projects;
  late final List<EnvironmentRecord> _environments;
  late final List<HostScopeBinding> _bindings;
  late final List<WorkTask> _tasks;
  late String _domainId;
  late String _milestoneId;
  late Set<String> _projectIds;
  late Set<String> _environmentIds;
  late Set<String> _modelKeys;
  late TaskProcessingMode _processingMode;
  late bool _requestMeta;
  late bool _derive;
  late bool _followup;
  late bool _autoAccept;
  String? _parentTaskId;
  late Set<String> _relatedTaskIds;
  String? _error;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    final canonical = CanonicalRepository(widget.workspace);
    _domains = canonical
        .list(EntityKind.domain)
        .where((item) => item.data['status'] == 'active')
        .toList();
    _milestones = canonical
        .list(EntityKind.milestone)
        .where((item) => item.data['status'] == 'active')
        .toList();
    _projects = canonical.list(EntityKind.project);
    _environments = EnvironmentService(widget.workspace).list();
    _bindings = HostBindingRegistry(widget.workspace).list();
    _tasks = TaskRepository(
      widget.workspace,
    ).list().where((item) => item.id != task?.id).toList();
    _title = TextEditingController(text: task?.title ?? '');
    _draft = TextEditingController(text: task?.promptDraft ?? '');
    _depth = TextEditingController(text: '${task?.maxGenerationDepth ?? 2}');
    _domainId = task?.domainId ?? '';
    _milestoneId = task?.milestoneId ?? '';
    _projectIds = {...?task?.projectIds};
    _environmentIds = {...?task?.effectiveTargetEnvironmentIds};
    _modelKeys = {...?task?.modelSelectionKeys};
    _processingMode = task?.processingMode ?? TaskProcessingMode.manual;
    _requestMeta = false;
    _derive = task?.autoDeriveTasks ?? false;
    _followup = task?.autoFollowupTasks ?? false;
    _autoAccept = task?.autoAcceptGeneratedTasks ?? false;
    _parentTaskId = task?.parentTaskId;
    _relatedTaskIds = {...?task?.relatedTaskIds};
  }

  @override
  void dispose() {
    _title.dispose();
    _draft.dispose();
    _depth.dispose();
    super.dispose();
  }

  List<CanonicalEntity> get _availableMilestones => _domainId.isEmpty
      ? const []
      : _milestones
            .where((item) => item.data['domain_id'] == _domainId)
            .toList();

  List<CanonicalEntity> get _availableProjects => _projects.where((item) {
    if (_projectIds.contains(item.id)) return true;
    if (item.data['status'] != 'active') return false;
    if (_domainId.isEmpty) return true;
    final scope = item.data['scope'];
    if (scope is! Map) return false;
    final domainIds = scope['domain_ids'];
    return scope['domain_id'] == _domainId ||
        (domainIds is List && domainIds.contains(_domainId));
  }).toList();

  List<String> get _availableEnvironmentIds {
    final ids = {
      ..._environmentIds,
      ..._environments
          .where((item) => item.status == 'active')
          .map((item) => item.id),
    }.toList()..sort();
    return ids;
  }

  List<String> get _availableModelKeys {
    final keys = <String>{..._modelKeys};
    for (final binding in _bindings) {
      if (_environmentIds.isNotEmpty &&
          !_environmentIds.contains(binding.environmentId)) {
        continue;
      }
      if (_domainId.isNotEmpty &&
          binding.domainId.isNotEmpty &&
          binding.domainId != _domainId) {
        continue;
      }
      keys.addAll(binding.modelBindings.keys);
    }
    return keys.toList()..sort();
  }

  String _label(CanonicalEntity entity) =>
      '${entity.data['title'] ?? entity.data['name'] ?? entity.id} · ${entity.id}';

  String _environmentLabel(String id) {
    for (final environment in _environments) {
      if (environment.id == id) return '${environment.alias} · $id';
    }
    return id;
  }

  Widget _multiSelect({
    required String title,
    required Iterable<(String, String)> options,
    required Set<String> selected,
  }) => ExpansionTile(
    title: Text('$title (${selected.length})'),
    children: [
      for (final option in options)
        CheckboxListTile(
          dense: true,
          title: Text(option.$2),
          value: selected.contains(option.$1),
          onChanged: (checked) => setState(() {
            checked == true
                ? selected.add(option.$1)
                : selected.remove(option.$1);
          }),
        ),
    ],
  );

  void _submit() {
    final title = _title.text.trim();
    final draft = _draft.text.trim();
    final depth = int.tryParse(_depth.text.trim());
    if (title.isEmpty) {
      setState(() => _error = 'Title is required.');
      return;
    }
    if (_milestoneId.isNotEmpty && _domainId.isEmpty) {
      setState(() => _error = 'Milestone requires a Domain.');
      return;
    }
    if (_requestMeta && draft.isEmpty) {
      setState(() => _error = 'Meta request requires a Prompt Draft.');
      return;
    }
    if (depth == null || depth < 0 || depth > 8) {
      setState(() => _error = 'Generation depth must be between 0 and 8.');
      return;
    }
    Navigator.pop(
      context,
      TaskConfigurationDraft(
        title: title,
        promptDraft: draft,
        domainId: _domainId,
        milestoneId: _milestoneId,
        projectIds: _projectIds.toList()..sort(),
        environmentIds: _environmentIds.toList()..sort(),
        modelSelectionKeys: _modelKeys.toList()..sort(),
        processingMode: _processingMode,
        requestMeta: _requestMeta,
        autoDeriveTasks: _derive,
        autoFollowupTasks: _followup,
        autoAcceptGeneratedTasks: _autoAccept,
        maxGenerationDepth: depth,
        parentTaskId: _parentTaskId,
        relatedTaskIds: _relatedTaskIds.toList()..sort(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.task == null ? 'Create Task' : 'Task configuration'),
      content: SizedBox(
        width: 680,
        height: 680,
        child: ListView(
          children: [
            TextField(
              key: const Key('task-title'),
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            if (widget.task == null)
              TextField(
                key: const Key('task-draft'),
                controller: _draft,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(labelText: 'Prompt Draft'),
              ),
            DropdownButtonFormField<String>(
              key: const Key('task-domain'),
              initialValue: _domainId,
              decoration: const InputDecoration(labelText: 'Domain (optional)'),
              items: [
                const DropdownMenuItem(value: '', child: Text('No Domain')),
                for (final domain in _domains)
                  DropdownMenuItem(
                    value: domain.id,
                    child: Text(_label(domain)),
                  ),
              ],
              onChanged: (value) => setState(() {
                _domainId = value ?? '';
                if (!_availableMilestones.any(
                  (item) => item.id == _milestoneId,
                )) {
                  _milestoneId = '';
                }
                final allowed = _availableProjects
                    .map((item) => item.id)
                    .toSet();
                _projectIds.removeWhere((id) => !allowed.contains(id));
              }),
            ),
            DropdownButtonFormField<String>(
              key: const Key('task-milestone'),
              initialValue: _milestoneId,
              decoration: const InputDecoration(
                labelText: 'Milestone (optional)',
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('No Milestone')),
                for (final milestone in _availableMilestones)
                  DropdownMenuItem(
                    value: milestone.id,
                    child: Text(_label(milestone)),
                  ),
              ],
              onChanged: (value) => setState(() => _milestoneId = value ?? ''),
            ),
            _multiSelect(
              title: 'Related Projects',
              options: _availableProjects.map(
                (item) => (item.id, _label(item)),
              ),
              selected: _projectIds,
            ),
            _multiSelect(
              title: 'Execution Environments',
              options: _availableEnvironmentIds.map(
                (id) => (id, _environmentLabel(id)),
              ),
              selected: _environmentIds,
            ),
            _multiSelect(
              title: 'Portable model selections',
              options: _availableModelKeys.map((key) => (key, key)),
              selected: _modelKeys,
            ),
            DropdownButtonFormField<TaskProcessingMode>(
              key: const Key('task-processing-mode'),
              initialValue: _processingMode,
              decoration: const InputDecoration(labelText: 'Processing mode'),
              items: [
                for (final mode in TaskProcessingMode.values)
                  DropdownMenuItem(value: mode, child: Text(mode.name)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _processingMode = value);
              },
            ),
            if (widget.task == null)
              SwitchListTile(
                key: const Key('task-request-meta'),
                title: const Text('Request Meta Prompt after creation'),
                value: _requestMeta,
                onChanged: (value) => setState(() => _requestMeta = value),
              ),
            SwitchListTile(
              title: const Text('Generate child Tasks'),
              value: _derive,
              onChanged: (value) => setState(() => _derive = value),
            ),
            SwitchListTile(
              title: const Text('Generate related Tasks'),
              value: _followup,
              onChanged: (value) => setState(() => _followup = value),
            ),
            SwitchListTile(
              title: const Text('Automatically accept generated Tasks'),
              subtitle: const Text('Meta approval remains required.'),
              value: _autoAccept,
              onChanged: _derive || _followup
                  ? (value) => setState(() => _autoAccept = value)
                  : null,
            ),
            TextField(
              controller: _depth,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Maximum generation depth',
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: _parentTaskId ?? '',
              decoration: const InputDecoration(labelText: 'Parent Task'),
              items: [
                const DropdownMenuItem(value: '', child: Text('No parent')),
                for (final task in _tasks)
                  DropdownMenuItem(
                    value: task.id,
                    child: Text('${task.title} · ${task.id}'),
                  ),
              ],
              onChanged: (value) => setState(() {
                _parentTaskId = value == null || value.isEmpty ? null : value;
                if (_parentTaskId != null) {
                  _relatedTaskIds.remove(_parentTaskId);
                }
              }),
            ),
            _multiSelect(
              title: 'Related Tasks',
              options: _tasks
                  .where((task) => task.id != _parentTaskId)
                  .map((task) => (task.id, '${task.title} · ${task.id}')),
              selected: _relatedTaskIds,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-task-configuration'),
          onPressed: _submit,
          child: Text(widget.task == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}
