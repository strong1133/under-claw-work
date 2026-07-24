import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/worklog_core.dart';
import 'design_tokens.dart';
import 'status_pill.dart';
import 'typography.dart';

/// Environment registry management surface (requirement 4).
///
/// All reads and writes go exclusively through the Worklog Core
/// [EnvironmentService]; this widget never edits the canonical YAML directly.
/// Layout is a dense master/detail panel pair with a keyboard-first command bar
/// (Ctrl/Cmd+R refresh, Ctrl/Cmd+N register-this-host), the kind of density and
/// keyboard affordance expected from a native terminal-adjacent tool.
class EnvironmentManagementScreen extends StatefulWidget {
  const EnvironmentManagementScreen({super.key, required this.workspaceRoot});

  final Directory workspaceRoot;

  @override
  State<EnvironmentManagementScreen> createState() =>
      _EnvironmentManagementScreenState();
}

class _EnvironmentManagementScreenState
    extends State<EnvironmentManagementScreen> {
  late final EnvironmentService _service;
  List<EnvironmentRecord> _records = const [];
  String? _selectedId;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _service = EnvironmentService(Workspace(widget.workspaceRoot));
    _reload();
  }

  void _reload() {
    final records = _service.list();
    setState(() {
      _records = records;
      _selectedId =
          records.where((r) => r.id == _selectedId).firstOrNull?.id ??
          records.firstOrNull?.id;
    });
  }

  EnvironmentRecord? get _selected =>
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

  Future<void> _registerThisHost() async {
    final controller = TextEditingController(text: 'This host');
    final alias = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Register this host'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Alias'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Register'),
          ),
        ],
      ),
    );
    if (alias == null || alias.trim().isEmpty) return;
    _run(() {
      final identity = EnvironmentIdentity.detect(
        Workspace(widget.workspaceRoot),
      );
      final record = _service.register(identity: identity, alias: alias.trim());
      return 'Registered ${record.id} (${record.alias}).';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyR, control: true):
            const _RefreshIntent(),
        SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            const _RefreshIntent(),
        SingleActivator(LogicalKeyboardKey.keyN, control: true):
            const _RegisterIntent(),
        SingleActivator(LogicalKeyboardKey.keyN, meta: true):
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
              _registerThisHost();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Environments'),
              actions: [
                _CommandHint(
                  label: 'Register host',
                  shortcut: '⌘N',
                  icon: Icons.add,
                  onPressed: _registerThisHost,
                ),
                _CommandHint(
                  label: 'Refresh',
                  shortcut: '⌘R',
                  icon: Icons.sync,
                  onPressed: _reload,
                ),
                const SizedBox(width: AppTokens.spaceSm),
              ],
            ),
            body: Row(
              children: [
                SizedBox(
                  width: AppTokens.panelWidth,
                  child: _EnvironmentList(
                    records: _records,
                    selectedId: _selectedId,
                    onSelected: (id) => setState(() => _selectedId = id),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _selected == null
                      ? const _EmptyDetail()
                      : _EnvironmentDetail(
                          key: ValueKey(_selected!.id),
                          record: _selected!,
                          message: _message,
                          isError: _isError,
                          onRename: (alias) => _run(() {
                            final r = _service.rename(_selected!.id, alias);
                            return 'Alias updated to "${r.alias}".';
                          }),
                          onKind: (kind) => _run(() {
                            _service.setKind(_selected!.id, kind);
                            return 'Kind set to $kind.';
                          }),
                          onCapabilities: (caps) => _run(() {
                            _service.setCapabilities(_selected!.id, caps);
                            return 'Capabilities updated.';
                          }),
                          onToggleActive: () => _run(() {
                            final r = _selected!;
                            if (r.isActive) {
                              _service.deactivate(r.id);
                              return '${r.id} deactivated.';
                            }
                            _service.activate(r.id);
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

class _CommandHint extends StatelessWidget {
  const _CommandHint({
    required this.label,
    required this.shortcut,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final String shortcut;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppTokens.spaceSm),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text('$label  $shortcut'),
      ),
    );
  }
}

class _EnvironmentList extends StatelessWidget {
  const _EnvironmentList({
    required this.records,
    required this.selectedId,
    required this.onSelected,
  });

  final List<EnvironmentRecord> records;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Text(
            'No environments registered.\nUse Register host (⌘N).',
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
            record.alias,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(record.id, style: AppTypography.mono()),
          trailing: StatusPill(kind: kind, label: record.status),
          onTap: () => onSelected(record.id),
        );
      },
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Select an environment',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }
}

class _EnvironmentDetail extends StatefulWidget {
  const _EnvironmentDetail({
    super.key,
    required this.record,
    required this.message,
    required this.isError,
    required this.onRename,
    required this.onKind,
    required this.onCapabilities,
    required this.onToggleActive,
  });

  final EnvironmentRecord record;
  final String? message;
  final bool isError;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onKind;
  final ValueChanged<List<String>> onCapabilities;
  final VoidCallback onToggleActive;

  @override
  State<_EnvironmentDetail> createState() => _EnvironmentDetailState();
}

class _EnvironmentDetailState extends State<_EnvironmentDetail> {
  late final TextEditingController _alias;
  late final TextEditingController _capabilities;

  static const _kinds = ['desktop', 'server', 'headless', 'agent_runtime'];

  @override
  void initState() {
    super.initState();
    _alias = TextEditingController(text: widget.record.alias);
    _capabilities = TextEditingController(
      text: widget.record.capabilities.join(', '),
    );
  }

  @override
  void dispose() {
    _alias.dispose();
    _capabilities.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final theme = Theme.of(context);
    final kind = AppStatusStyle.kindForLifecycle(record.status);
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceXl),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(record.alias, style: theme.textTheme.headlineMedium),
            ),
            StatusPill(kind: kind, label: record.status),
          ],
        ),
        const SizedBox(height: AppTokens.spaceXs),
        SelectableText(record.id, style: AppTypography.mono()),
        const SizedBox(height: AppTokens.spaceXl),

        _Field(
          label: 'Alias (editable display name — never an identity key)',
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _alias,
                  decoration: const InputDecoration(hintText: 'Alias'),
                  onSubmitted: widget.onRename,
                ),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              FilledButton(
                onPressed: () => widget.onRename(_alias.text),
                child: const Text('Save alias'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTokens.spaceLg),

        _Field(
          label: 'Kind',
          child: Wrap(
            spacing: AppTokens.spaceSm,
            children: [
              for (final option in _kinds)
                ChoiceChip(
                  label: Text(option),
                  selected: record.kind == option,
                  onSelected: (_) => widget.onKind(option),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppTokens.spaceLg),

        _Field(
          label: 'Capabilities (comma-separated)',
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _capabilities,
                  decoration: const InputDecoration(
                    hintText: 'git, gui, docker',
                  ),
                  onSubmitted: (value) => widget.onCapabilities(_split(value)),
                ),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              OutlinedButton(
                onPressed: () =>
                    widget.onCapabilities(_split(_capabilities.text)),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTokens.spaceLg),

        _Field(
          label: 'Identity (immutable)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                'machine_key: ${record.machineKey}',
                style: AppTypography.mono(),
              ),
              Text(
                '${record.os} · ${record.architecture}',
                style: theme.textTheme.bodySmall,
              ),
              if (record.previousMachineKeys.isNotEmpty)
                Text(
                  'previous keys: ${record.previousMachineKeys.length}',
                  style: theme.textTheme.bodySmall,
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
                record.isActive
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
              label: Text(record.isActive ? 'Deactivate' : 'Activate'),
            ),
          ],
        ),
        if (widget.message != null) ...[
          const SizedBox(height: AppTokens.spaceLg),
          Row(
            children: [
              Icon(
                widget.isError
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                size: 16,
                color: widget.isError
                    ? AppTokens.statusDanger
                    : AppTokens.statusSuccess,
              ),
              const SizedBox(width: AppTokens.spaceXs),
              Expanded(
                child: Text(
                  widget.message!,
                  style: TextStyle(
                    color: widget.isError
                        ? AppTokens.statusDanger
                        : AppTokens.statusSuccess,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  List<String> _split(String value) =>
      value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
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
