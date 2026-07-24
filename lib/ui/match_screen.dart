import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/worklog_core.dart';
import 'design_tokens.dart';
import 'status_pill.dart';
import 'typography.dart';

/// Match review surface (requirement 4 / management-screens task).
///
/// Reads and transitions matches exclusively through [MatchService]; the widget
/// never edits canonical YAML directly. Review state is shown as a StatusPill
/// (colour + icon + text, never colour alone) and the immutable audit history is
/// rendered in full. Approve/reject/revoke are enabled only from states the
/// service permits, so the UI cannot request an illegal transition.
class MatchReviewScreen extends StatefulWidget {
  const MatchReviewScreen({
    super.key,
    required this.workspaceRoot,
    this.actorId = 'user:operator',
  });

  final Directory workspaceRoot;

  /// The reviewing principal recorded in the audit. A generic placeholder by
  /// default — never a specific agent/model identity baked into the schema.
  final String actorId;

  @override
  State<MatchReviewScreen> createState() => _MatchReviewScreenState();
}

class _MatchReviewScreenState extends State<MatchReviewScreen> {
  late final MatchService _matches;
  List<MatchRecord> _records = const [];
  String? _selectedId;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _matches = MatchService(Workspace(widget.workspaceRoot));
    _reload();
  }

  void _reload() {
    final records = _matches.list();
    setState(() {
      _records = records;
      _selectedId =
          records.where((r) => r.id == _selectedId).firstOrNull?.id ??
          records.firstOrNull?.id;
    });
  }

  MatchRecord? get _selected =>
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

  /// User-initiated (manual) match creation — the "사용자가 매칭" half of
  /// requirement 2. Opens a picker over Knowledge/Reference subjects and
  /// Domain/Milestone/Objective/Task targets and proposes a `manual` match.
  Future<void> _openNewMatch() async {
    final subjects = _matches.subjectCandidates();
    final targets = _matches.targetCandidates();
    if (subjects.isEmpty || targets.isEmpty) {
      setState(() {
        _message =
            'Create at least one Knowledge/Reference and one '
            'Domain/Milestone/Objective/Task before matching.';
        _isError = true;
      });
      return;
    }
    var subjectId = subjects.first.id;
    var targetId = targets.first.id;
    final note = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('New match'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: subjectId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Subject (Knowledge / Reference)',
                  ),
                  items: [
                    for (final c in subjects)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text(
                          '[${c.kind}] ${c.label} · ${c.id}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialog(() => subjectId = value ?? subjectId),
                ),
                const SizedBox(height: AppTokens.spaceLg),
                DropdownButtonFormField<String>(
                  initialValue: targetId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Target (Domain / Milestone / Objective / Task)',
                  ),
                  items: [
                    for (final c in targets)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text(
                          '[${c.kind}] ${c.label} · ${c.id}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialog(() => targetId = value ?? targetId),
                ),
                const SizedBox(height: AppTokens.spaceLg),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional, recorded as source)',
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
              child: const Text('Propose'),
            ),
          ],
        ),
      ),
    );
    final source = note.text.trim();
    note.dispose();
    if (confirmed != true) return;
    _run(() {
      final record = _matches.propose(
        subjectId: subjectId,
        targetId: targetId,
        actorType: 'user',
        actorId: widget.actorId,
        source: source,
      );
      _selectedId = record.id;
      return '${record.id} proposed (manual).';
    });
  }

  /// Agent-initiated automatic matching — the "agent가 매칭" half of
  /// requirement 2. Proposals land in `proposed` for human review.
  void _runAutoMatch() {
    _run(() {
      final created = _matches.autoMatch(actorId: 'agent:auto-match');
      if (created.isEmpty) {
        return 'Auto-match found no new candidates above the threshold.';
      }
      _selectedId = created.first.id;
      return 'Auto-match proposed ${created.length} agent '
          'match${created.length == 1 ? '' : 'es'} for review.';
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
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _RefreshIntent: CallbackAction<_RefreshIntent>(
            onInvoke: (_) {
              _reload();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Match review'),
              actions: [
                Semantics(
                  button: true,
                  label: 'Propose a new match',
                  child: FilledButton.icon(
                    onPressed: _openNewMatch,
                    icon: const Icon(Icons.add_link, size: 16),
                    label: const Text('New match'),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceSm),
                Semantics(
                  button: true,
                  label: 'Run agent auto-match',
                  child: OutlinedButton.icon(
                    onPressed: _runAutoMatch,
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('Auto-match'),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceSm),
                Semantics(
                  button: true,
                  label: 'Refresh matches',
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
                  child: _MatchList(
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
                            'No matches proposed.',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        )
                      : _MatchDetail(
                          key: ValueKey(_selected!.id),
                          record: _selected!,
                          message: _message,
                          isError: _isError,
                          onApprove: () => _run(() {
                            _matches.approve(
                              _selected!.id,
                              actorType: 'user',
                              actorId: widget.actorId,
                            );
                            return '${_selected!.id} approved.';
                          }),
                          onReject: () => _run(() {
                            _matches.reject(
                              _selected!.id,
                              actorType: 'user',
                              actorId: widget.actorId,
                            );
                            return '${_selected!.id} rejected.';
                          }),
                          onRevoke: () => _run(() {
                            _matches.revoke(
                              _selected!.id,
                              actorType: 'user',
                              actorId: widget.actorId,
                            );
                            return '${_selected!.id} revoked.';
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

class _MatchList extends StatelessWidget {
  const _MatchList({
    required this.records,
    required this.selectedId,
    required this.onSelected,
  });

  final List<MatchRecord> records;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Text(
            'No matches to review.',
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
        final kind = AppStatusStyle.kindForReview(record.reviewState);
        return ListTile(
          selected: record.id == selectedId,
          title: Text(
            '${record.subjectId} → ${record.targetId}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.mono(size: 13),
          ),
          subtitle: Text(
            '${record.matchMode} · ${record.id}',
            style: AppTypography.mono(size: 12),
          ),
          trailing: StatusPill(kind: kind, label: record.reviewState),
          onTap: () => onSelected(record.id),
        );
      },
    );
  }
}

class _MatchDetail extends StatelessWidget {
  const _MatchDetail({
    super.key,
    required this.record,
    required this.message,
    required this.isError,
    required this.onApprove,
    required this.onReject,
    required this.onRevoke,
  });

  final MatchRecord record;
  final String? message;
  final bool isError;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = AppStatusStyle.kindForReview(record.reviewState);
    final canApprove = record.reviewState == 'proposed';
    final canReject = record.reviewState == 'proposed';
    final canRevoke =
        record.reviewState == 'approved' || record.reviewState == 'proposed';
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceXl),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${record.subjectId} → ${record.targetId}',
                style: AppTypography.mono(size: AppTypography.sizeTitle),
              ),
            ),
            StatusPill(kind: kind, label: record.reviewState),
          ],
        ),
        const SizedBox(height: AppTokens.spaceXs),
        SelectableText(record.id, style: AppTypography.mono(size: 13)),
        const SizedBox(height: AppTokens.spaceXl),
        Wrap(
          spacing: AppTokens.spaceSm,
          runSpacing: AppTokens.spaceSm,
          children: [
            Chip(label: Text('mode: ${record.matchMode}')),
            Chip(label: Text('actor: ${record.actorId}')),
            if (record.confidence != null)
              Chip(label: Text('confidence: ${record.confidence}')),
          ],
        ),
        if (record.evidence.isNotEmpty) ...[
          const SizedBox(height: AppTokens.spaceLg),
          _Field(label: 'Evidence', child: Text(record.evidence)),
        ],
        if (record.source.isNotEmpty) ...[
          const SizedBox(height: AppTokens.spaceLg),
          _Field(label: 'Source', child: Text(record.source)),
        ],
        const SizedBox(height: AppTokens.spaceXl),
        Text('Review actions', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppTokens.spaceSm),
        Wrap(
          spacing: AppTokens.spaceSm,
          runSpacing: AppTokens.spaceSm,
          children: [
            FilledButton.icon(
              onPressed: canApprove ? onApprove : null,
              icon: const Icon(Icons.check),
              label: const Text('Approve'),
            ),
            OutlinedButton.icon(
              onPressed: canReject ? onReject : null,
              icon: const Icon(Icons.block),
              label: const Text('Reject'),
            ),
            OutlinedButton.icon(
              onPressed: canRevoke ? onRevoke : null,
              icon: const Icon(Icons.merge_type),
              label: const Text('Revoke'),
            ),
          ],
        ),
        const SizedBox(height: AppTokens.spaceXl),
        Text('Audit history (append-only)', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppTokens.spaceSm),
        for (final entry in record.history)
          if (entry is Map) _HistoryTile(entry: entry),
        if (message != null) ...[
          const SizedBox(height: AppTokens.spaceLg),
          _MessageBar(message: message!, isError: isError),
        ],
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry});

  final Map<Object?, Object?> entry;

  @override
  Widget build(BuildContext context) {
    final state = '${entry['state']}';
    final kind = AppStatusStyle.kindForReview(state);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusPill(kind: kind, label: state),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry['action']} · ${entry['actor_type']}:${entry['actor_id']}',
                ),
                Text('${entry['at']}', style: AppTypography.mono(size: 12)),
                if (entry['reason'] != null) Text('reason: ${entry['reason']}'),
              ],
            ),
          ),
        ],
      ),
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
