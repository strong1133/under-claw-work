import 'package:flutter/foundation.dart';

enum NotionConnectionStatus {
  disconnected,
  connecting,
  connected,
  syncing,
  error,
}

enum NotionConflictChoice { keepGit, applyNotion, postpone }

@immutable
class NotionConnectionDraft {
  const NotionConnectionDraft({
    required this.secretLocator,
    required this.token,
    required this.databaseIds,
  });

  final String secretLocator;
  final String token;
  final Map<String, String> databaseIds;
}

@immutable
class NotionConflictView {
  const NotionConflictView({
    required this.canonicalId,
    required this.title,
    required this.gitValue,
    required this.notionValue,
    this.authoritative = false,
  });

  final String canonicalId;
  final String title;
  final String gitValue;
  final String notionValue;
  final bool authoritative;
}

@immutable
class NotionSyncViewState {
  const NotionSyncViewState({
    this.status = NotionConnectionStatus.disconnected,
    this.message = 'Notion is not connected.',
    this.lastSyncedAt,
    this.pushed = 0,
    this.pulled = 0,
    this.conflicts = const [],
  });

  final NotionConnectionStatus status;
  final String message;
  final DateTime? lastSyncedAt;
  final int pushed;
  final int pulled;
  final List<NotionConflictView> conflicts;
}

/// UI-facing boundary. The composition root adapts the Core coordinator to this
/// interface; widgets never receive a token after [connect] returns.
abstract interface class NotionUiController {
  ValueListenable<NotionSyncViewState> get state;

  Future<void> connect(NotionConnectionDraft draft);

  Future<void> syncNow();

  Future<void> resolveConflict(String canonicalId, NotionConflictChoice choice);
}
