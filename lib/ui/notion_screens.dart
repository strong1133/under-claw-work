import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'notion_sync_port.dart';
import 'status_pill.dart';

class NotionSetupView extends StatefulWidget {
  const NotionSetupView({super.key, required this.controller});

  final NotionUiController controller;

  @override
  State<NotionSetupView> createState() => _NotionSetupViewState();
}

class _NotionSetupViewState extends State<NotionSetupView> {
  final _token = TextEditingController();
  final _databases = {
    for (final type in const [
      'domain',
      'milestone',
      'objective',
      'task',
      'knowledge',
      'reference',
      'environment',
      'agent',
      'match',
    ])
      type: TextEditingController(),
  };

  @override
  void dispose() {
    _token.dispose();
    for (final controller in _databases.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    await widget.controller.connect(
      NotionConnectionDraft(
        secretLocator: 'os-secure-store://under-claw-work/notion',
        token: _token.text,
        databaseIds: {
          for (final entry in _databases.entries)
            if (entry.value.text.trim().isNotEmpty)
              entry.key: entry.value.text.trim(),
        },
      ),
    );
    _token.clear();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(AppTokens.spaceXl),
    children: [
      Text('Notion setup', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: AppTokens.spaceLg),
      TextField(
        key: const Key('notion-token'),
        controller: _token,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'Integration token',
          helperText: 'Stored only in the operating system secure store.',
        ),
      ),
      const SizedBox(height: AppTokens.spaceLg),
      for (final entry in _databases.entries) ...[
        TextField(
          key: Key('notion-db-${entry.key}'),
          controller: entry.value,
          decoration: InputDecoration(labelText: '${entry.key} database ID'),
        ),
        const SizedBox(height: AppTokens.spaceSm),
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          key: const Key('notion-connect'),
          onPressed: _connect,
          icon: const Icon(Icons.link),
          label: const Text('Connect and test'),
        ),
      ),
    ],
  );
}

class NotionSyncView extends StatelessWidget {
  const NotionSyncView({super.key, required this.controller});

  final NotionUiController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.state,
    builder: (context, state, _) => ListView(
      padding: const EdgeInsets.all(AppTokens.spaceXl),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Notion sync',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            StatusPill(
              label: state.status.name,
              kind: switch (state.status) {
                NotionConnectionStatus.connected => AppStatusKind.success,
                NotionConnectionStatus.error => AppStatusKind.danger,
                NotionConnectionStatus.syncing ||
                NotionConnectionStatus.connecting => AppStatusKind.info,
                _ => AppStatusKind.neutral,
              },
            ),
          ],
        ),
        const SizedBox(height: AppTokens.spaceLg),
        Text(state.message),
        Text('Pushed ${state.pushed} · Pulled ${state.pulled}'),
        Text(
          state.lastSyncedAt == null
              ? 'Never synced'
              : 'Last synced ${state.lastSyncedAt!.toLocal()}',
        ),
        const SizedBox(height: AppTokens.spaceLg),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('notion-sync-now'),
            onPressed: state.status == NotionConnectionStatus.syncing
                ? null
                : controller.syncNow,
            icon: const Icon(Icons.sync),
            label: const Text('Sync now'),
          ),
        ),
      ],
    ),
  );
}

class NotionConflictViewScreen extends StatelessWidget {
  const NotionConflictViewScreen({super.key, required this.controller});

  final NotionUiController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.state,
    builder: (context, state, _) => ListView(
      padding: const EdgeInsets.all(AppTokens.spaceXl),
      children: [
        Text('Sync conflicts', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AppTokens.spaceLg),
        if (state.conflicts.isEmpty) const Text('No unresolved conflicts.'),
        for (final conflict in state.conflicts)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${conflict.title} · ${conflict.canonicalId}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text('Git: ${conflict.gitValue}'),
                  Text('Notion: ${conflict.notionValue}'),
                  const SizedBox(height: AppTokens.spaceMd),
                  Wrap(
                    spacing: AppTokens.spaceSm,
                    children: [
                      FilledButton(
                        onPressed: () => controller.resolveConflict(
                          conflict.canonicalId,
                          NotionConflictChoice.keepGit,
                        ),
                        child: const Text('Keep Git'),
                      ),
                      OutlinedButton(
                        onPressed: conflict.authoritative
                            ? null
                            : () => controller.resolveConflict(
                                conflict.canonicalId,
                                NotionConflictChoice.applyNotion,
                              ),
                        child: const Text('Apply Notion'),
                      ),
                      TextButton(
                        onPressed: () => controller.resolveConflict(
                          conflict.canonicalId,
                          NotionConflictChoice.postpone,
                        ),
                        child: const Text('Postpone'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
