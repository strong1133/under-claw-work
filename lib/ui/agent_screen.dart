import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/worklog_core.dart';
import 'design_tokens.dart';
import 'status_pill.dart';
import 'typography.dart';

/// Agent registry management surface (requirement 4 / management-screens task).
///
/// All reads and writes go exclusively through [AgentRegistryService]; the
/// widget never edits canonical YAML directly. Every Agent is bound to an
/// Environment by its immutable ENV id, so the register/rebind flows offer only
/// existing environments (sourced from [EnvironmentService]). Density, master/
/// detail layout, StatusPill (colour+icon+text) and keyboard command bar mirror
/// the Environment screen so the shell reads as one system.
class AgentManagementScreen extends StatefulWidget {
  const AgentManagementScreen({super.key, required this.workspaceRoot});

  final Directory workspaceRoot;

  @override
  State<AgentManagementScreen> createState() => _AgentManagementScreenState();
}

class _AgentManagementScreenState extends State<AgentManagementScreen> {
  late final AgentRegistryService _agents;
  late final EnvironmentService _environments;
  List<AgentRecord> _records = const [];
  List<EnvironmentRecord> _envs = const [];
  String? _selectedId;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    final workspace = Workspace(widget.workspaceRoot);
    _agents = AgentRegistryService(workspace);
    _environments = EnvironmentService(workspace);
    _reload();
  }

  void _reload() {
    final records = _agents.list();
    setState(() {
      _records = records;
      _envs = _environments.list();
      _selectedId =
          records.where((r) => r.id == _selectedId).firstOrNull?.id ??
          records.firstOrNull?.id;
    });
  }

  AgentRecord? get _selected =>
      _records.where((r) => r.id == _selectedId).firstOrNull;

  void _run(String Function() action) {
    try {
      final note = action();
      _reload();
      setState(() {
        _message = note;
        _isError = false;
      });
    } catch (error) {
      setState(() {
        _message = error.toString();
        _isError = true;
      });
    }
  }

  Future<void> _registerAgent() async {
    if (_envs.isEmpty) {
      setState(() {
        _message = 'Register an environment first — an agent must bind to one.';
        _isError = true;
      });
      return;
    }
    final name = TextEditingController();
    final kind = TextEditingController(text: 'generic');
    var envId = _envs.first.id;
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Register agent'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                TextField(
                  controller: kind,
                  decoration: const InputDecoration(labelText: 'Kind'),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                DropdownButtonFormField<String>(
                  initialValue: envId,
                  decoration: const InputDecoration(labelText: 'Environment'),
                  items: [
                    for (final env in _envs)
                      DropdownMenuItem(
                        value: env.id,
                        child: Text('${env.alias} · ${env.id}'),
                      ),
                  ],
                  onChanged: (value) => setDialog(() => envId = value ?? envId),
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
              child: const Text('Register'),
            ),
          ],
        ),
      ),
    );
    if (created != true) return;
    _run(() {
      final record = _agents.register(
        name: name.text,
        kind: kind.text,
        environmentId: envId,
      );
      return 'Registered ${record.id} (${record.name}).';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            const _RefreshIntent(),
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            const _RefreshIntent(),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            const _RegisterIntent(),
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            const _RegisterIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _RefreshIntent: CallbackAction<_RefreshIntent>(
            onInvoke: (_) {
              _reload();
              return null;
            },
          ),
          _RegisterIntent: CallbackAction<_RegisterIntent>(
            onInvoke: (_) {
              _registerAgent();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Agents'),
              actions: [
                Semantics(
                  button: true,
                  label: 'Register agent',
                  child: OutlinedButton.icon(
                    onPressed: _registerAgent,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Register agent  ⌘N'),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceSm),
                Semantics(
                  button: true,
                  label: 'Refresh agents',
                  child: OutlinedButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text('Refresh  ⌘R'),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceSm),
              ],
            ),
            body: Row(
              children: [
                SizedBox(
                  width: AppTokens.panelWidth,
                  child: _AgentList(
                    records: _records,
                    selectedId: _selectedId,
                    onSelected: (id) => setState(() => _selectedId = id),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _selected == null
                      ? Center(
                          child: Text(
                            'No agents registered.\nRegister one with ⌘N.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        )
                      : _AgentDetail(
                          key: ValueKey(_selected!.id),
                          record: _selected!,
                          environments: _envs,
                          message: _message,
                          isError: _isError,
                          onRename: (name) => _run(() {
                            final r = _agents.rename(_selected!.id, name);
                            return 'Name updated to "${r.name}".';
                          }),
                          onBind: (envId) => _run(() {
                            _agents.bindEnvironment(_selected!.id, envId);
                            return 'Bound to $envId.';
                          }),
                          onToggleActive: () => _run(() {
                            final r = _selected!;
                            if (r.status == 'active') {
                              _agents.deactivate(r.id);
                              return '${r.id} deactivated.';
                            }
                            _agents.activate(r.id);
                            return '${r.id} activated.';
                          }),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RefreshIntent extends Intent {
  const _RefreshIntent();
}

class _RegisterIntent extends Intent {
  const _RegisterIntent();
}

class _AgentList extends StatelessWidget {
  const _AgentList({
    required this.records,
    required this.selectedId,
    required this.onSelected,
  });

  final List<AgentRecord> records;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Text(
            'No agents yet.\nUse Register agent (⌘N).',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
      itemCount: records.length,
      itemBuilder: (context, index) {
        final record = records[index];
        final kind = AppStatusStyle.kindForLifecycle(record.status);
        return ListTile(
          selected: record.id == selectedId,
          title: Text(
            record.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(record.id, style: AppTypography.mono(size: 12)),
          trailing: StatusPill(kind: kind, label: record.status),
          onTap: () => onSelected(record.id),
        );
      },
    );
  }
}

class _AgentDetail extends StatefulWidget {
  const _AgentDetail({
    super.key,
    required this.record,
    required this.environments,
    required this.message,
    required this.isError,
    required this.onRename,
    required this.onBind,
    required this.onToggleActive,
  });

  final AgentRecord record;
  final List<EnvironmentRecord> environments;
  final String? message;
  final bool isError;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onBind;
  final VoidCallback onToggleActive;

  @override
  State<_AgentDetail> createState() => _AgentDetailState();
}

class _AgentDetailState extends State<_AgentDetail> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.record.name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final theme = Theme.of(context);
    final kind = AppStatusStyle.kindForLifecycle(record.status);
    final boundExists = widget.environments.any(
      (e) => e.id == record.environmentId,
    );
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceXl),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(record.name, style: theme.textTheme.headlineMedium),
            ),
            StatusPill(kind: kind, label: record.status),
          ],
        ),
        const SizedBox(height: AppTokens.spaceXs),
        SelectableText(record.id, style: AppTypography.mono(size: 13)),
        const SizedBox(height: AppTokens.spaceXl),
        _Field(
          label: 'Name (editable display name — never an identity key)',
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(hintText: 'Name'),
                  onSubmitted: widget.onRename,
                ),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              FilledButton(
                onPressed: () => widget.onRename(_name.text),
                child: const Text('Save name'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTokens.spaceLg),
        _Field(
          label: 'Kind',
          child: Text(record.kind, style: theme.textTheme.bodyLarge),
        ),
        const SizedBox(height: AppTokens.spaceLg),
        _Field(
          label: 'Environment binding (immutable ENV id)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!boundExists)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTokens.spaceXs),
                  child: StatusPill(
                    kind: AppStatusKind.warning,
                    label: 'bound env missing',
                  ),
                ),
              DropdownButtonFormField<String>(
                initialValue: boundExists ? record.environmentId : null,
                decoration: const InputDecoration(labelText: 'Environment'),
                items: [
                  for (final env in widget.environments)
                    DropdownMenuItem(
                      value: env.id,
                      child: Text('${env.alias} · ${env.id}'),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) widget.onBind(value);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTokens.spaceXl),
        Wrap(
          spacing: AppTokens.spaceSm,
          children: [
            OutlinedButton.icon(
              onPressed: widget.onToggleActive,
              icon: Icon(
                record.status == 'active'
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
              label: Text(
                record.status == 'active' ? 'Deactivate' : 'Activate',
              ),
            ),
          ],
        ),
        if (widget.message != null) ...[
          const SizedBox(height: AppTokens.spaceLg),
          _MessageBar(message: widget.message!, isError: widget.isError),
        ],
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: AppTokens.spaceSm),
        child,
      ],
    );
  }
}

class _MessageBar extends StatelessWidget {
  const _MessageBar({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? AppTokens.statusDanger : AppTokens.statusSuccess;
    return Semantics(
      liveRegion: true,
      label: isError ? 'Error: $message' : message,
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: AppTokens.spaceXs),
          Expanded(
            child: Text(message, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}
