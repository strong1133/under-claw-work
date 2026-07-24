import 'package:flutter/material.dart';

import 'design_tokens.dart';

@immutable
class WorkspaceDestination {
  const WorkspaceDestination({
    required this.label,
    required this.icon,
    required this.child,
  });

  final String label;
  final IconData icon;
  final Widget child;
}

/// Dense, keyboard-friendly workspace frame shared by graph, runtime, memory and
/// integration surfaces. It owns navigation only; all writes stay in Core-backed
/// child screens.
class UnifiedWorkspaceShell extends StatefulWidget {
  const UnifiedWorkspaceShell({
    super.key,
    required this.destinations,
    this.title = 'Under Claw Work',
  });

  final String title;
  final List<WorkspaceDestination> destinations;

  @override
  State<UnifiedWorkspaceShell> createState() => _UnifiedWorkspaceShellState();
}

class _UnifiedWorkspaceShellState extends State<UnifiedWorkspaceShell> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    assert(widget.destinations.isNotEmpty);
    final selected = widget.destinations[_selected];
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1100;
        return Scaffold(
          body: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      key: const Key('workspace-rail'),
                      width: compact ? 72 : 248,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        border: Border(
                          right: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!compact) ...[
                            Padding(
                              padding: const EdgeInsets.all(AppTokens.spaceLg),
                              child: Text(
                                widget.title,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            const Divider(),
                          ],
                          Expanded(
                            child: ListView.builder(
                              itemCount: widget.destinations.length,
                              itemBuilder: (context, index) {
                                final destination = widget.destinations[index];
                                return Tooltip(
                                  message: destination.label,
                                  child: ListTile(
                                    key: Key('workspace-destination-$index'),
                                    selected: index == _selected,
                                    leading: Icon(destination.icon),
                                    title: compact
                                        ? null
                                        : Text(destination.label),
                                    onTap: () =>
                                        setState(() => _selected = index),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!compact)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppTokens.spaceLg,
                                vertical: AppTokens.spaceMd,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                border: Border(
                                  bottom: BorderSide(
                                    color: Theme.of(context).dividerColor,
                                  ),
                                ),
                              ),
                              child: Text(
                                selected.label,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          Expanded(child: selected.child),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _WorkspaceStatusBar(
                title: widget.title,
                destinationLabel: selected.label,
                index: _selected,
                total: widget.destinations.length,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Persistent bottom status/command bar — the Warp/Orca signature chrome. Shows
/// the workspace identity on the left and the active destination position on the
/// right, styled from tokens so it reads as one system with the rail and header.
class _WorkspaceStatusBar extends StatelessWidget {
  const _WorkspaceStatusBar({
    required this.title,
    required this.destinationLabel,
    required this.index,
    required this.total,
  });

  final String title;
  final String destinationLabel;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('workspace-status-bar'),
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 8, color: AppTokens.statusSuccess),
          const SizedBox(width: AppTokens.spaceSm),
          Text(title, style: theme.textTheme.bodySmall),
          const Spacer(),
          Text(
            '$destinationLabel · ${index + 1}/$total',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
