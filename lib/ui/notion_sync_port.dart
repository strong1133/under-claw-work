import 'package:flutter/foundation.dart';

enum NotionConnectionStatus {
  disconnected,
  connecting,
  connected,
  syncing,
  error,
}

enum NotionConflictChoice { keepGit, applyNotion, postpone }

enum NotionConflictCardStatus { pending, resolving, postponed, failed }

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
    required this.conflictId,
    required this.canonicalId,
    required this.type,
    required this.remoteRevision,
    required this.gitProperties,
    required this.notionProperties,
    this.authoritativeFields = const {},
    this.status = NotionConflictCardStatus.pending,
    this.errorMessage,
  });

  final String conflictId;
  final String canonicalId;
  final String type;
  final String remoteRevision;
  final Map<String, Object?> gitProperties;
  final Map<String, Object?> notionProperties;
  final Set<String> authoritativeFields;
  final NotionConflictCardStatus status;
  final String? errorMessage;

  NotionConflictView copyWith({
    NotionConflictCardStatus? status,
    String? errorMessage,
    bool clearError = false,
  }) => NotionConflictView(
    conflictId: conflictId,
    canonicalId: canonicalId,
    type: type,
    remoteRevision: remoteRevision,
    gitProperties: gitProperties,
    notionProperties: notionProperties,
    authoritativeFields: authoritativeFields,
    status: status ?? this.status,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
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

  NotionSyncViewState copyWith({
    NotionConnectionStatus? status,
    String? message,
    DateTime? lastSyncedAt,
    int? pushed,
    int? pulled,
    List<NotionConflictView>? conflicts,
  }) => NotionSyncViewState(
    status: status ?? this.status,
    message: message ?? this.message,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    pushed: pushed ?? this.pushed,
    pulled: pulled ?? this.pulled,
    conflicts: conflicts ?? this.conflicts,
  );
}

/// UI-facing boundary. The composition root adapts the Core coordinator to this
/// interface; widgets never receive a token after [connect] returns.
abstract interface class NotionUiController {
  ValueListenable<NotionSyncViewState> get state;

  Future<void> connect(NotionConnectionDraft draft);

  Future<void> syncNow();

  Future<void> resolveConflict(String conflictId, NotionConflictChoice choice);
}
