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
          body: Row(
            children: [
              Container(
                key: const Key('workspace-rail'),
                width: compact ? 72 : 248,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    right: BorderSide(color: Theme.of(context).dividerColor),
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
                              title: compact ? null : Text(destination.label),
                              onTap: () => setState(() => _selected = index),
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
        );
      },
    );
  }
}
