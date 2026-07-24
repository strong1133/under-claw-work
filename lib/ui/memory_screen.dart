import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/worklog_core.dart';
import 'design_tokens.dart';
import 'status_pill.dart';
import 'typography.dart';

/// Cross-agent memory recall surface (requirement 4 / management-screens task).
///
/// Recalls Knowledge for a Domain/Milestone/Task scope exclusively through
/// [MemoryRecallService]. Current vs. superseded items and each item's
/// provenance are shown with StatusPill (colour + icon + text). Restricted/secret
/// material is fail-closed: with no capability issuer wired, ticking "include
/// restricted" surfaces the service's explicit refusal instead of leaking
/// anything.
class MemoryRecallScreen extends StatefulWidget {
  const MemoryRecallScreen({super.key, required this.workspaceRoot});

  final Directory workspaceRoot;

  @override
  State<MemoryRecallScreen> createState() => _MemoryRecallScreenState();
}

class _MemoryRecallScreenState extends State<MemoryRecallScreen> {
  late final MemoryRecallService _service;
  final _domain = TextEditingController();
  final _milestone = TextEditingController();
  final _task = TextEditingController();
  bool _includeRestricted = false;
  RecallResult? _result;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    // No RecallCapabilityIssuer is provided, so restricted recall is impossible
    // (fail-closed): the service refuses rather than trusting a caller flag.
    _service = MemoryRecallService(Workspace(widget.workspaceRoot));
  }

  @override
  void dispose() {
    _domain.dispose();
    _milestone.dispose();
    _task.dispose();
    super.dispose();
  }

  String? _trimmed(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  void _recall() {
    try {
      final result = _service.recall(
        domainId: _trimmed(_domain),
        milestoneId: _trimmed(_milestone),
        taskId: _trimmed(_task),
        includeRestricted: _includeRestricted,
      );
      setState(() {
        _result = result;
        _isError = false;
        _message =
            '${result.current.length} current · ${result.superseded.length} '
            'superseded · ${result.contributingActors.length} contributing '
            'actor(s).';
      });
    } catch (error) {
      // A restricted recall without a verifiable capability lands here — the
      // fail-closed StateError is surfaced, nothing restricted is shown.
      setState(() {
        _result = null;
        _isError = true;
        _message = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            const _RecallIntent(),
        const SingleActivator(LogicalKeyboardKey.enter, meta: true):
            const _RecallIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _RecallIntent: CallbackAction<_RecallIntent>(
            onInvoke: (_) {
              _recall();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(title: const Text('Memory recall')),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppTokens.spaceLg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: AppTokens.spaceMd,
                        runSpacing: AppTokens.spaceSm,
                        children: [
                          _ScopeField(controller: _domain, label: 'Domain ID'),
                          _ScopeField(
                            controller: _milestone,
                            label: 'Milestone ID',
                          ),
                          _ScopeField(controller: _task, label: 'Task ID'),
                        ],
                      ),
                      const SizedBox(height: AppTokens.spaceSm),
                      Row(
                        children: [
                          Semantics(
                            label: 'Include restricted knowledge',
                            checked: _includeRestricted,
                            child: Checkbox(
                              value: _includeRestricted,
                              onChanged: (v) => setState(
                                () => _includeRestricted = v ?? false,
                              ),
                            ),
                          ),
                          const Text('Include restricted (fail-closed)'),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: _recall,
                            icon: const Icon(Icons.search),
                            label: const Text('Recall  ⌘⏎'),
                          ),
                        ],
                      ),
                      if (_message != null) ...[
                        const SizedBox(height: AppTokens.spaceSm),
                        _MessageBar(message: _message!, isError: _isError),
                      ],
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _result == null
                      ? Center(
                          child: Text(
                            'Enter a scope and recall.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        )
                      : _RecallResultView(result: _result!),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecallIntent extends Intent {
  const _RecallIntent();
}

class _ScopeField extends StatelessWidget {
  const _ScopeField({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: TextField(
        controller: controller,
        style: AppTypography.mono(),
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}

class _RecallResultView extends StatelessWidget {
  const _RecallResultView({required this.result});

  final RecallResult result;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      children: [
        Text('Current', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTokens.spaceSm),
        if (result.current.isEmpty)
          const Text('No current knowledge in scope.')
        else
          for (final item in result.current) _KnowledgeTile(item: item),
        const SizedBox(height: AppTokens.spaceXl),
        Text('Superseded', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTokens.spaceSm),
        if (result.superseded.isEmpty)
          const Text('No superseded knowledge in scope.')
        else
          for (final item in result.superseded) _KnowledgeTile(item: item),
      ],
    );
  }
}

class _KnowledgeTile extends StatelessWidget {
  const _KnowledgeTile({required this.item});

  final RecalledKnowledge item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = item.isCurrent ? AppStatusKind.success : AppStatusKind.neutral;
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(item.title, style: theme.textTheme.titleMedium),
                ),
                StatusPill(
                  kind: kind,
                  label: item.isCurrent ? 'current' : 'superseded',
                ),
              ],
            ),
            const SizedBox(height: AppTokens.spaceXs),
            Text(item.id, style: AppTypography.mono(size: 12)),
            const SizedBox(height: AppTokens.spaceSm),
            Wrap(
              spacing: AppTokens.spaceSm,
              runSpacing: AppTokens.spaceXs,
              children: [
                Chip(label: Text('actor: ${item.actorId}')),
                Chip(label: Text('origin: ${item.origin}')),
                Chip(label: Text('confidence: ${item.confidence}')),
                Chip(label: Text('via: ${item.provenance}')),
              ],
            ),
            if (item.supersededBy.isNotEmpty) ...[
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                'superseded by: ${item.supersededBy.join(', ')}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (item.contradictedBy.isNotEmpty) ...[
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                'contradicted by: ${item.contradictedBy.join(', ')}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (item.derivedFrom.isNotEmpty) ...[
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                'derived from: ${item.derivedFrom.join(', ')}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
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
