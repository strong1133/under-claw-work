import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'auth.dart';
import 'canonical_repository.dart';
import 'match_service.dart';
import 'workspace.dart';

/// Unforgeable capability an authenticated caller must present to recall
/// restricted or secret Knowledge.
///
/// The gap this closes (g2): a public `const` constructor let any caller mint a
/// value carrying [restrictedScope] and bypass authentication. This value can
/// now only be produced by a [RecallCapabilityIssuer] that first validated a
/// live [AuthGrant], and it carries an HMAC signature the *same* issuer must
/// verify before restricted material is returned. Two defences stack:
///
///  1. The scope-bearing constructor is private, so code outside this library
///     (including tests, which are a separate library) simply cannot construct
///     one — a plain `includeRestricted` flag can never fabricate a capability.
///  2. Even a value obtained from a *different* issuer (a forged/attacker
///     secret) fails signature verification against the trusted issuer, so a
///     capability minted elsewhere cannot be replayed.
class RecallAuthorization {
  const RecallAuthorization._({
    required this.actorId,
    required this.scopes,
    required this.expiresAt,
    required this.signature,
  });

  /// The authenticated principal (environment/user) the authorization binds to.
  final String actorId;

  /// Granted capability scopes (e.g. [restrictedScope]).
  final Set<String> scopes;

  /// Hard expiry inherited from the underlying [AuthGrant]; a capability is
  /// refused once its grant would have expired even if the signature matches.
  final DateTime expiresAt;

  /// Opaque HMAC over (actorId, scopes, expiry) keyed by the issuer secret.
  /// Safe to hold; it proves provenance but reveals no secret.
  final String signature;

  /// Scope string that unlocks restricted/secret Knowledge recall.
  static const restrictedScope = 'knowledge:restricted';

  bool get canReadRestricted => scopes.contains(restrictedScope);
}

/// Mints and verifies [RecallAuthorization] capabilities against a process-held
/// secret. The same instance (or one sharing the secret) must both issue and
/// verify; a capability signed by any other secret fails verification, so a
/// forger who cannot invoke the private constructor and does not hold the
/// secret cannot produce an accepted capability.
class RecallCapabilityIssuer {
  RecallCapabilityIssuer(this._secret)
    : assert(_secret.length >= 16, 'issuer secret must be at least 16 bytes');

  /// Convenience issuer with an ephemeral, cryptographically-random secret —
  /// suitable for a single process/session (and for tests).
  factory RecallCapabilityIssuer.ephemeral() {
    final random = Random.secure();
    return RecallCapabilityIssuer(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
  }

  final List<int> _secret;

  /// Issues a capability from a live [AuthGrant] validated against [context].
  /// An expired or wrongly-bound grant throws, so restricted recall fails
  /// closed.
  RecallAuthorization issue(
    AuthGrant grant,
    AuthContext context, {
    Set<String> scopes = const {RecallAuthorization.restrictedScope},
    DateTime? now,
  }) {
    final at = (now ?? DateTime.now()).toUtc();
    if (!grant.isValidFor(context, at)) {
      throw StateError(
        'Restricted recall requires a live, correctly-bound auth grant.',
      );
    }
    final scopeSet = {...scopes};
    final expiresAt = grant.expiresAt.toUtc();
    return RecallAuthorization._(
      actorId: context.environmentId,
      scopes: scopeSet,
      expiresAt: expiresAt,
      signature: _sign(context.environmentId, scopeSet, expiresAt),
    );
  }

  /// Returns true only when [authorization] is unexpired and its signature
  /// matches this issuer's secret. Any tampering with actor, scopes or expiry,
  /// or a signature from another secret, verifies false.
  bool verify(RecallAuthorization authorization, {DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    if (!authorization.expiresAt.toUtc().isAfter(at)) return false;
    final expected = _sign(
      authorization.actorId,
      authorization.scopes,
      authorization.expiresAt,
    );
    return _constantTimeEquals(expected, authorization.signature);
  }

  String _sign(String actorId, Set<String> scopes, DateTime expiresAt) {
    final canonical =
        '$actorId|${(scopes.toList()..sort()).join(',')}'
        '|${expiresAt.toUtc().toIso8601String()}';
    return Hmac(sha256, _secret).convert(utf8.encode(canonical)).toString();
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var mismatch = 0;
    for (var i = 0; i < a.length; i++) {
      mismatch |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return mismatch == 0;
  }
}

/// One recalled Knowledge item with its cross-agent provenance and relation
/// state resolved.
class RecalledKnowledge {
  RecalledKnowledge({
    required this.id,
    required this.title,
    required this.body,
    required this.actorId,
    required this.origin,
    required this.confidence,
    required this.provenance,
    required this.supersededBy,
    required this.contradictedBy,
    required this.derivedFrom,
    this.updatedAt = '',
  });

  final String id;
  final String title;
  final String body;

  /// ISO-8601 last-update timestamp used to order recall freshest-first.
  final String updatedAt;

  /// The agent/user that authored the Knowledge (from origin/created_by).
  final String actorId;
  final String origin;
  final String confidence;

  /// How this item entered the recall scope (scope.* or an approved match id).
  final String provenance;

  /// Knowledge ids that supersede this one (this item is stale if non-empty).
  final List<String> supersededBy;
  final List<String> contradictedBy;
  final List<String> derivedFrom;

  bool get isCurrent => supersededBy.isEmpty;
}

class RecallResult {
  RecallResult({required this.current, required this.superseded});

  /// Current (non-superseded) items, freshest-relevant first.
  final List<RecalledKnowledge> current;

  /// Items kept for provenance but shadowed by a newer supersede.
  final List<RecalledKnowledge> superseded;

  /// Distinct authoring agents/users represented in the recall.
  Set<String> get contributingActors => {
    for (final item in [...current, ...superseded]) item.actorId,
  };
}

/// Cross-agent unified memory recall.
///
/// Knowledge written by any agent is recalled for the same Domain/Milestone/
/// Task scope — directly through the item scope or indirectly through an
/// approved [MatchService] match. Reads exclusively from the Git-canonical
/// store, so recall survives a full SQLite/agentmemory projection rebuild.
class MemoryRecallService {
  MemoryRecallService(
    this.workspace, {
    RecallCapabilityIssuer? capabilityVerifier,
  }) : repository = CanonicalRepository(workspace),
       _verifier = capabilityVerifier;

  final Workspace workspace;
  final CanonicalRepository repository;

  /// Trusted verifier for restricted-recall capabilities. When absent (the
  /// default), restricted recall is impossible: no capability can be verified,
  /// so the service fails closed rather than trusting a caller-supplied value.
  final RecallCapabilityIssuer? _verifier;

  /// Recalls Knowledge for a Domain/Milestone/Task scope.
  ///
  /// Restricted/secret Knowledge is excluded by default. It is only returned
  /// when [includeRestricted] is set **and** an [authorization] that carries
  /// [RecallAuthorization.restrictedScope] is supplied. Passing
  /// `includeRestricted: true` without such an authorization fails closed with
  /// a [StateError] rather than silently leaking restricted material.
  RecallResult recall({
    String? domainId,
    String? milestoneId,
    String? taskId,
    bool includeRestricted = false,
    RecallAuthorization? authorization,
    DateTime? now,
  }) {
    final allowRestricted =
        includeRestricted &&
        authorization != null &&
        authorization.canReadRestricted &&
        (_verifier?.verify(authorization, now: now) ?? false);
    if (includeRestricted && !allowRestricted) {
      throw StateError(
        'Restricted recall requires a verifiable, unexpired authorization '
        'carrying the "${RecallAuthorization.restrictedScope}" scope, issued '
        'by the trusted capability issuer.',
      );
    }
    final approvedMatchTargets = <String, String>{}; // knowledgeId -> matchId
    for (final match in MatchService(workspace).list()) {
      if (match.reviewState != 'approved') continue;
      if (!(match.subjectId.startsWith('KNW-'))) continue;
      final target = match.targetId;
      if (target == domainId || target == milestoneId || target == taskId) {
        approvedMatchTargets[match.subjectId] = match.id;
      }
    }

    final knowledge = repository.list(EntityKind.knowledge);
    // Index supersede edges so a stale item can be shadowed regardless of which
    // agent authored the newer fact.
    final supersededBy = <String, List<String>>{};
    for (final entity in knowledge) {
      final relations = entity.data['relations'];
      if (relations is Map) {
        for (final target in _ids(relations['supersedes'])) {
          (supersededBy[target] ??= []).add(entity.id);
        }
      }
    }

    final current = <RecalledKnowledge>[];
    final superseded = <RecalledKnowledge>[];
    for (final entity in knowledge) {
      final provenance = _provenance(
        entity,
        domainId,
        milestoneId,
        taskId,
        approvedMatchTargets,
      );
      if (provenance == null) continue;
      if (!allowRestricted && _isRestricted(entity)) continue;
      final relations = entity.data['relations'];
      final item = RecalledKnowledge(
        id: entity.id,
        title: (entity.data['title'] ?? entity.data['name'] ?? entity.id)
            .toString(),
        body: entity.body,
        actorId: _actorId(entity),
        origin: _origin(entity),
        confidence: (entity.data['confidence'] ?? 'unknown').toString(),
        provenance: provenance,
        supersededBy: supersededBy[entity.id] ?? const [],
        contradictedBy: relations is Map
            ? _ids(relations['contradicts'])
            : const [],
        derivedFrom: relations is Map
            ? _ids(relations['derived_from'])
            : const [],
        updatedAt:
            (entity.data['updated_at'] ?? entity.data['created_at'] ?? '')
                .toString(),
      );
      if (item.isCurrent) {
        current.add(item);
      } else {
        superseded.add(item);
      }
    }
    // Freshest-relevant first: newer updated_at wins; id is a stable tiebreak
    // so recall order is deterministic across a projection rebuild.
    int byRecency(RecalledKnowledge a, RecalledKnowledge b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    }

    current.sort(byRecency);
    superseded.sort(byRecency);
    return RecallResult(current: current, superseded: superseded);
  }

  String? _provenance(
    CanonicalEntity entity,
    String? domainId,
    String? milestoneId,
    String? taskId,
    Map<String, String> approvedMatchTargets,
  ) {
    final scope = entity.data['scope'];
    if (scope is Map) {
      if (taskId != null && _ids(scope['task_ids']).contains(taskId)) {
        return 'scope.task';
      }
      if (milestoneId != null &&
          (_ids(scope['milestone_ids']).contains(milestoneId) ||
              scope['milestone_id'] == milestoneId)) {
        return 'scope.milestone';
      }
      if (domainId != null &&
          (_ids(scope['domain_ids']).contains(domainId) ||
              scope['domain_id'] == domainId)) {
        return 'scope.domain';
      }
    }
    final matchId = approvedMatchTargets[entity.id];
    if (matchId != null) return 'match:$matchId';
    return null;
  }

  bool _isRestricted(CanonicalEntity entity) {
    final visibility = entity.data['visibility'];
    return visibility == 'restricted' || visibility == 'secret';
  }

  String _actorId(CanonicalEntity entity) {
    final origin = entity.data['origin'];
    if (origin is Map && origin['actor_id'] != null) {
      return origin['actor_id'].toString();
    }
    final createdBy = entity.data['created_by'];
    if (createdBy is Map && createdBy['actor_id'] != null) {
      return createdBy['actor_id'].toString();
    }
    return 'unknown';
  }

  String _origin(CanonicalEntity entity) {
    final origin = entity.data['origin'];
    if (origin is Map && origin['kind'] != null) {
      return origin['kind'].toString();
    }
    return 'unknown';
  }

  List<String> _ids(Object? value) {
    if (value is List) return value.whereType<String>().toList();
    if (value is String && value.isNotEmpty) return [value];
    return const [];
  }
}
