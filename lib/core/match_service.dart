import 'canonical_repository.dart';
import 'id.dart';
import 'workspace.dart';

/// The canonical subject of a match: a Knowledge or Reference item.
enum MatchSubjectKind {
  knowledge(EntityKind.knowledge),
  reference(EntityKind.reference);

  const MatchSubjectKind(this.entityKind);
  final EntityKind entityKind;

  static MatchSubjectKind fromId(String id) {
    for (final value in values) {
      if (id.startsWith('${value.entityKind.prefix}-')) return value;
    }
    throw FormatException('Unsupported match subject id: $id');
  }
}

/// The canonical target of a match: a Domain, Milestone, Objective, or Task.
enum MatchTargetKind {
  domain(EntityKind.domain),
  milestone(EntityKind.milestone),
  objective(EntityKind.objective),
  task(EntityKind.task);

  const MatchTargetKind(this.entityKind);
  final EntityKind entityKind;

  static MatchTargetKind fromId(String id) {
    for (final value in values) {
      if (id.startsWith('${value.entityKind.prefix}-')) return value;
    }
    throw FormatException('Unsupported match target id: $id');
  }
}

/// A many-to-many provenance-tracked link between a Knowledge/Reference item
/// and a Domain/Milestone/Objective/Task, with an immutable review audit.
class MatchRecord {
  const MatchRecord(this.entity);

  final CanonicalEntity entity;

  String get id => entity.id;
  Map<String, Object?> get data => entity.data;

  String get subjectId => (data['subject'] as Map)['id'] as String;
  String get targetId => (data['target'] as Map)['id'] as String;
  String get matchMode => data['match_mode'] as String;
  String get reviewState => data['review_state'] as String;
  String get actorId => (data['actor'] as Map)['actor_id'] as String;
  num? get confidence => data['confidence'] as num?;
  String get evidence => (data['evidence'] as String?) ?? '';
  String get source => (data['source'] as String?) ?? '';
  List<Object?> get history => (data['history'] as List?) ?? const [];
}

/// A selectable canonical entity offered as a match subject or target. Carries
/// a human label so the picker never shows a bare id, and the canonical [kind]
/// so the caller can group Knowledge/Reference subjects and
/// Domain/Milestone/Objective/Task targets.
class MatchCandidate {
  const MatchCandidate({
    required this.id,
    required this.label,
    required this.kind,
  });

  final String id;
  final String label;
  final String kind;
}

/// Records and reviews Knowledge/Reference ↔ Domain/Milestone/Objective/Task
/// matches. Each match is a Git-canonical document with referential integrity
/// enforced by [CanonicalRepository]; every review transition appends an
/// immutable history entry and emits an immutable audit Event.
class MatchService {
  MatchService(this.workspace) : repository = CanonicalRepository(workspace);

  final Workspace workspace;
  final CanonicalRepository repository;

  List<MatchRecord> list() =>
      repository.list(EntityKind.match).map(MatchRecord.new).toList();

  /// Knowledge and Reference items that may be matched (the subject side).
  List<MatchCandidate> subjectCandidates() => [
    for (final e in repository.list(EntityKind.knowledge))
      _candidate(e, MatchSubjectKind.knowledge.name),
    for (final e in repository.list(EntityKind.reference))
      _candidate(e, MatchSubjectKind.reference.name),
  ];

  /// Domain/Milestone/Objective/Task items a subject may be matched to.
  List<MatchCandidate> targetCandidates() => [
    for (final e in repository.list(EntityKind.domain))
      _candidate(e, MatchTargetKind.domain.name),
    for (final e in repository.list(EntityKind.milestone))
      _candidate(e, MatchTargetKind.milestone.name),
    for (final e in repository.list(EntityKind.objective))
      _candidate(e, MatchTargetKind.objective.name),
    for (final e in repository.list(EntityKind.task))
      _candidate(e, MatchTargetKind.task.name),
  ];

  MatchCandidate _candidate(CanonicalEntity entity, String kind) =>
      MatchCandidate(
        id: entity.id,
        label: (entity.data['title'] ?? entity.data['name'] ?? entity.id)
            .toString(),
        kind: kind,
      );

  /// Agent-side automatic matching (requirement 2, the "agent가 매칭" half).
  ///
  /// Scans every Knowledge/Reference subject against every candidate target and
  /// proposes an `agent`-mode match wherever their labels share enough salient
  /// terms. The shared terms become the required explainable [evidence], and the
  /// term-overlap ratio becomes the confidence. Proposals always land in
  /// `proposed` (never auto-approved here) so a human still reviews them — the
  /// agent can originate matches without bypassing the review gate. Pairs that
  /// already have an active (non-rejected, non-revoked) match are skipped, so
  /// the pass is idempotent.
  List<MatchRecord> autoMatch({
    required String actorId,
    double threshold = 0.5,
  }) {
    final subjects = subjectCandidates();
    final targets = targetCandidates();
    final active = <String>{
      for (final match in list())
        if (match.reviewState != 'rejected' && match.reviewState != 'revoked')
          '${match.subjectId}->${match.targetId}',
    };
    final created = <MatchRecord>[];
    for (final subject in subjects) {
      final subjectTerms = _terms(subject.label);
      if (subjectTerms.isEmpty) continue;
      for (final target in targets) {
        final pair = '${subject.id}->${target.id}';
        if (active.contains(pair)) continue;
        final shared = subjectTerms.intersection(_terms(target.label));
        if (shared.isEmpty) continue;
        final score = shared.length / subjectTerms.length;
        if (score < threshold) continue;
        final match = propose(
          subjectId: subject.id,
          targetId: target.id,
          actorType: 'agent',
          actorId: actorId,
          mode: 'agent',
          confidence: double.parse(score.toStringAsFixed(2)),
          evidence: 'Shared terms: ${(shared.toList()..sort()).join(', ')}',
          source: 'auto-match:label-term-overlap',
        );
        created.add(match);
        active.add(pair);
      }
    }
    return created;
  }

  static const _stopwords = <String>{
    'the',
    'and',
    'for',
    'with',
    'from',
    'into',
    'this',
    'that',
    'not',
    'are',
    'was',
    'has',
    'have',
    'its',
    'per',
    'via',
    'new',
    'old',
  };

  /// Lower-cased salient terms of a label: latin words of length ≥ 3 that are
  /// not stopwords, plus CJK runs of length ≥ 2. Deterministic and
  /// language-agnostic enough to explain a match by its shared vocabulary.
  Set<String> _terms(String text) {
    final terms = <String>{};
    for (final token in text.toLowerCase().split(RegExp(r'[^0-9a-z가-힣]+'))) {
      if (token.isEmpty) continue;
      final isCjk = RegExp(r'[가-힣]').hasMatch(token);
      if (isCjk) {
        if (token.length >= 2) terms.add(token);
      } else if (token.length >= 3 && !_stopwords.contains(token)) {
        terms.add(token);
      }
    }
    return terms;
  }

  MatchRecord? get(String id) {
    final entity = repository.get(EntityKind.match, id);
    return entity == null ? null : MatchRecord(entity);
  }

  /// Every match touching a given subject or target id.
  List<MatchRecord> forEntity(String entityId) => list()
      .where(
        (match) => match.subjectId == entityId || match.targetId == entityId,
      )
      .toList();

  /// Proposes a match between [subjectId] (Knowledge/Reference) and [targetId]
  /// (Domain/Milestone/Objective/Task).
  ///
  /// [mode] records how the candidate was produced (manual/agent/hybrid).
  /// Agent proposals may be auto-confirmed when [confidence] meets
  /// [autoApproveThreshold] — an explainable policy gate, off by default.
  MatchRecord propose({
    required String subjectId,
    required String targetId,
    required String actorType,
    required String actorId,
    String mode = 'manual',
    num? confidence,
    String evidence = '',
    String source = '',
    double? autoApproveThreshold,
  }) {
    final subjectKind = MatchSubjectKind.fromId(subjectId);
    final targetKind = MatchTargetKind.fromId(targetId);
    // Explainability policy (kept in lock-step with the contract validator):
    // agent- and hybrid-produced candidates must carry evidence so an
    // automated match is never opaque.
    if ((mode == 'agent' || mode == 'hybrid') && evidence.trim().isEmpty) {
      throw ArgumentError.value(
        evidence,
        'evidence',
        'is required for $mode-produced matches',
      );
    }
    if (!repository.exists(subjectKind.entityKind, subjectId) &&
        !_taskExists(subjectId)) {
      throw StateError('Match subject does not exist: $subjectId');
    }
    if (!_targetExists(targetKind, targetId)) {
      throw StateError('Match target does not exist: $targetId');
    }
    final duplicate = list()
        .where(
          (match) =>
              match.subjectId == subjectId &&
              match.targetId == targetId &&
              match.reviewState != 'rejected' &&
              match.reviewState != 'revoked',
        )
        .firstOrNull;
    if (duplicate != null) {
      throw StateError(
        'An active match already links $subjectId and $targetId '
        '(${duplicate.id}).',
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final id = newId('MAT');
    final autoApprove =
        mode == 'agent' &&
        autoApproveThreshold != null &&
        confidence != null &&
        confidence >= autoApproveThreshold;
    final reviewState = autoApprove ? 'approved' : 'proposed';
    final data = <String, Object?>{
      'schema_version': 1,
      'id': id,
      'type': 'match',
      'subject': {'kind': subjectKind.name, 'id': subjectId},
      'target': {'kind': targetKind.name, 'id': targetId},
      'match_mode': mode,
      'actor': {'actor_type': actorType, 'actor_id': actorId},
      'review_state': reviewState,
      'confidence': ?confidence,
      'evidence': evidence,
      'source': source,
      // Canonical relation fields give referential integrity for free.
      if (subjectKind == MatchSubjectKind.knowledge)
        'knowledge_ids': [subjectId],
      if (subjectKind == MatchSubjectKind.reference)
        'reference_ids': [subjectId],
      if (targetKind == MatchTargetKind.domain) 'domain_id': targetId,
      if (targetKind == MatchTargetKind.milestone) 'milestone_id': targetId,
      if (targetKind == MatchTargetKind.objective) 'objective_ids': [targetId],
      if (targetKind == MatchTargetKind.task)
        'scope': {
          'task_ids': [targetId],
        },
      'history': [
        {
          'state': reviewState,
          'action': autoApprove ? 'auto_approved' : 'proposed',
          'actor_type': actorType,
          'actor_id': actorId,
          'at': now,
          if (evidence.isNotEmpty) 'evidence': evidence,
        },
      ],
      'created_at': now,
      'updated_at': now,
    };
    final created = repository.create(
      CanonicalEntity(kind: EntityKind.match, id: id, data: data),
    );
    _emitAudit(
      MatchRecord(created),
      state: reviewState,
      action: autoApprove ? 'auto_approved' : 'proposed',
      actorType: actorType,
      actorId: actorId,
      evidence: evidence,
    );
    return MatchRecord(created);
  }

  MatchRecord approve(
    String id, {
    required String actorType,
    required String actorId,
    String? reason,
  }) => _transition(
    id,
    'approved',
    'approve',
    actorType,
    actorId,
    reason,
    from: const {'proposed'},
  );

  MatchRecord reject(
    String id, {
    required String actorType,
    required String actorId,
    String? reason,
  }) => _transition(
    id,
    'rejected',
    'reject',
    actorType,
    actorId,
    reason,
    from: const {'proposed'},
  );

  /// Un-links a previously confirmed (or proposed) match while preserving its
  /// full history — a correction of a mis-match, not a deletion.
  MatchRecord revoke(
    String id, {
    required String actorType,
    required String actorId,
    String? reason,
  }) => _transition(
    id,
    'revoked',
    'revoke',
    actorType,
    actorId,
    reason,
    from: const {'approved', 'proposed'},
  );

  MatchRecord _transition(
    String id,
    String state,
    String action,
    String actorType,
    String actorId,
    String? reason, {
    required Set<String> from,
  }) {
    final current = get(id);
    if (current == null) throw StateError('Match does not exist: $id');
    if (!from.contains(current.reviewState)) {
      throw StateError(
        'Cannot $action a match in state ${current.reviewState}.',
      );
    }
    // A user approving an agent-proposed match makes the provenance genuinely
    // collaborative: the agent proposed the link and a human confirmed it. Record
    // that as `hybrid` so "both user and agent" is a first-class, visible
    // provenance (requirement 2's 둘다) rather than an implicit two-step workflow.
    // Evidence carried over from the agent proposal keeps the hybrid match
    // explainable, satisfying the same agent/hybrid evidence contract as propose.
    final promotesToHybrid =
        action == 'approve' &&
        actorType == 'user' &&
        current.matchMode == 'agent';
    final now = DateTime.now().toUtc().toIso8601String();
    final data = <String, Object?>{
      ...current.data,
      'review_state': state,
      if (promotesToHybrid) 'match_mode': 'hybrid',
      'history': [
        ...current.history,
        {
          'state': state,
          'action': action,
          'actor_type': actorType,
          'actor_id': actorId,
          'at': now,
          if (reason != null && reason.isNotEmpty) 'reason': reason,
        },
      ],
      'updated_at': now,
    };
    final updated = repository.update(
      CanonicalEntity(kind: EntityKind.match, id: id, data: data),
    );
    _emitAudit(
      MatchRecord(updated),
      state: state,
      action: action,
      actorType: actorType,
      actorId: actorId,
      reason: reason,
      evidence: current.evidence,
    );
    return MatchRecord(updated);
  }

  bool _taskExists(String id) =>
      id.startsWith('TSK-') && repository.exists(EntityKind.task, id);

  bool _targetExists(MatchTargetKind kind, String id) {
    if (kind == MatchTargetKind.task) return _taskExists(id);
    return repository.exists(kind.entityKind, id);
  }

  /// Emits an immutable `match_reviewed` Event that captures the full audit
  /// context (action, resulting state, reason, evidence, source, subject and
  /// target) of one review transition. Because every field the audit needs is
  /// recorded on the immutable Event stream, the complete correction history of
  /// a match is reconstructable from Events alone — even if the mutable
  /// `Match.history` were lost or tampered with.
  void _emitAudit(
    MatchRecord match, {
    required String state,
    required String action,
    required String actorType,
    required String actorId,
    String? reason,
    String? evidence,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final eventId = newId('EVT');
    final subject = match.data['subject'];
    final target = match.data['target'];
    repository.create(
      CanonicalEntity(
        kind: EntityKind.event,
        id: eventId,
        data: {
          'schema_version': 1,
          'id': eventId,
          'type': 'event',
          'event_type': 'match_reviewed',
          'match_id': match.id,
          'action': action,
          'review_state': state,
          'match_mode': match.matchMode,
          if (subject is Map) 'subject': Map<String, Object?>.from(subject),
          if (target is Map) 'target': Map<String, Object?>.from(target),
          'actor': {'actor_type': actorType, 'actor_id': actorId},
          if (evidence != null && evidence.trim().isNotEmpty)
            'evidence': evidence,
          if (match.source.trim().isNotEmpty) 'source': match.source,
          if (reason != null && reason.trim().isNotEmpty) 'reason': reason,
          'occurred_at': now,
        },
      ),
    );
  }
}
