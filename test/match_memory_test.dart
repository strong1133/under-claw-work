import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late EntityService entities;
  late ProjectionStore projection;

  const host = EnvironmentIdentity(
    machineKey: 'MK-host',
    os: 'macos',
    architecture: 'macosArm64',
  );

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-match-');
    workspace = Workspace(temporary)..ensureLayout();
    entities = EntityService(workspace);
    projection = ProjectionStore(workspace);
  });

  tearDown(() {
    projection.dispose();
    temporary.deleteSync(recursive: true);
  });

  ({
    CanonicalEntity domain,
    CanonicalEntity milestone,
    CanonicalEntity knowledge,
  })
  seed() {
    final domain = entities.create(kind: EntityKind.domain, title: 'Product');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'MVP',
      domainId: domain.id,
    );
    final knowledge = entities.create(
      kind: EntityKind.knowledge,
      title: 'ECFS quirk',
      body: 'The filing portal rate-limits bursts.',
      domainId: domain.id,
      milestoneId: milestone.id,
    );
    return (domain: domain, milestone: milestone, knowledge: knowledge);
  }

  group('Environment <-> Agent registry (gap 8)', () {
    test('agent registers against an ENV id and validates the link', () {
      final env = EnvironmentService(
        workspace,
      ).register(identity: host, alias: 'Workstation');
      final agent = AgentRegistryService(
        workspace,
      ).register(name: 'Hermes Main', kind: 'hermes', environmentId: env.id);
      expect(agent.environmentId, env.id);
      entities.validateGraph();

      // An agent bound to a missing environment is rejected.
      expect(
        () => AgentRegistryService(
          workspace,
        ).register(name: 'Ghost', kind: 'codex', environmentId: 'ENV-nope'),
        throwsStateError,
      );
    });
  });

  group('Match provenance vertical slice (requirement 2)', () {
    test('manual propose/approve/revoke keeps an immutable audit', () {
      final data = seed();
      final matches = MatchService(workspace);
      final proposed = matches.propose(
        subjectId: data.knowledge.id,
        targetId: data.milestone.id,
        actorType: 'user',
        actorId: 'user:jsj',
        evidence: 'Mentioned in kickoff notes.',
      );
      expect(proposed.reviewState, 'proposed');
      expect(proposed.matchMode, 'manual');

      final approved = matches.approve(
        proposed.id,
        actorType: 'user',
        actorId: 'user:jsj',
      );
      expect(approved.reviewState, 'approved');
      expect(approved.history, hasLength(2));

      // Duplicate active match is refused.
      expect(
        () => matches.propose(
          subjectId: data.knowledge.id,
          targetId: data.milestone.id,
          actorType: 'user',
          actorId: 'user:jsj',
        ),
        throwsStateError,
      );

      final revoked = matches.revoke(
        approved.id,
        actorType: 'user',
        actorId: 'user:jsj',
        reason: 'Wrong milestone.',
      );
      expect(revoked.reviewState, 'revoked');
      // History is append-only: earlier entries are preserved verbatim.
      expect(revoked.history, hasLength(3));
      expect((revoked.history.first as Map)['state'], 'proposed');

      // An audit Event was emitted for each transition.
      final events = CanonicalRepository(workspace)
          .list(EntityKind.event)
          .where((e) => e.data['event_type'] == 'match_reviewed')
          .toList();
      expect(events, hasLength(3));
    });

    test('agent auto-match confirms above the explainable threshold', () {
      final data = seed();
      final matches = MatchService(workspace);
      final auto = matches.propose(
        subjectId: data.knowledge.id,
        targetId: data.domain.id,
        actorType: 'agent',
        actorId: 'AGT-classifier',
        mode: 'agent',
        confidence: 0.95,
        evidence: 'concept overlap=0.95',
        autoApproveThreshold: 0.9,
      );
      expect(auto.reviewState, 'approved');
      expect(auto.confidence, 0.95);
      expect((auto.history.first as Map)['action'], 'auto_approved');

      // Below threshold stays proposed for human approval.
      final reference = entities.create(
        kind: EntityKind.reference,
        title: 'Manual',
        domainId: data.domain.id,
      );
      final pending = matches.propose(
        subjectId: reference.id,
        targetId: data.domain.id,
        actorType: 'agent',
        actorId: 'AGT-classifier',
        mode: 'agent',
        confidence: 0.4,
        evidence: 'concept overlap=0.40',
        autoApproveThreshold: 0.9,
      );
      expect(pending.reviewState, 'proposed');
    });

    test('candidate enumeration lists subjects and targets by kind', () {
      final data = seed();
      final reference = entities.create(
        kind: EntityKind.reference,
        title: 'Runbook',
        domainId: data.domain.id,
      );
      final matches = MatchService(workspace);
      final subjects = matches.subjectCandidates();
      final targets = matches.targetCandidates();
      expect(
        subjects.map((c) => c.id),
        containsAll([data.knowledge.id, reference.id]),
      );
      expect(
        subjects.every((c) => c.kind == 'knowledge' || c.kind == 'reference'),
        isTrue,
      );
      expect(
        targets.map((c) => c.id),
        containsAll([data.domain.id, data.milestone.id]),
      );
      // A label is always carried, never a bare id.
      expect(
        subjects.firstWhere((c) => c.id == data.knowledge.id).label,
        'ECFS quirk',
      );
    });

    test('autoMatch proposes reviewable agent matches from shared terms', () {
      seed();
      final domain = entities.create(
        kind: EntityKind.domain,
        title: 'Filing Portal',
      );
      entities.create(
        kind: EntityKind.knowledge,
        title: 'Filing Portal notes',
        body: 'Portal onboarding.',
        domainId: domain.id,
      );
      final matches = MatchService(workspace);
      final proposed = matches.autoMatch(actorId: 'agent:auto');
      final pair = proposed.where((m) => m.targetId == domain.id).toList();
      expect(pair, isNotEmpty, reason: 'shared term "portal" should match');
      final match = pair.first;
      // Agent-originated, evidence-backed, and NOT auto-approved: a human still
      // reviews it, so the review gate is preserved.
      expect(match.matchMode, 'agent');
      expect(match.reviewState, 'proposed');
      expect(match.actorId, 'agent:auto');
      expect(match.evidence.toLowerCase(), contains('portal'));
      expect(match.confidence, isNotNull);
      // A second pass is idempotent for the same active pair.
      final again = matches.autoMatch(actorId: 'agent:auto');
      expect(again.where((m) => m.targetId == domain.id), isEmpty);
    });

    test('match references survive a Git-only projection rebuild (gap 7)', () {
      final data = seed();
      final env = EnvironmentService(
        workspace,
      ).register(identity: host, alias: 'Workstation');
      AgentRegistryService(
        workspace,
      ).register(name: 'Hermes', kind: 'hermes', environmentId: env.id);
      TaskRepository(workspace).create(
        WorkTask(
          id: 'TSK-bound',
          domainId: data.domain.id,
          milestoneId: data.milestone.id,
          title: 'Bound task',
          status: TaskStatus.draft,
          promptDraft: '',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: env.id,
        ),
      );
      final match = MatchService(workspace).propose(
        subjectId: data.knowledge.id,
        targetId: 'TSK-bound',
        actorType: 'user',
        actorId: 'user:jsj',
      );

      // Throw away the SQLite projection and rebuild from Git canonical only.
      projection.dispose();
      if (workspace.database.existsSync()) workspace.database.deleteSync();
      projection = ProjectionStore(workspace);
      projection.rebuild();
      final db = projection.open();

      final envRow = db.select(
        "SELECT id FROM canonical_entities WHERE entity_type='environment'",
      );
      expect(envRow.single['id'], env.id);
      final agentRel = db.select(
        "SELECT target_id FROM entity_relations "
        "WHERE source_type='agent' AND relation='environment_id'",
      );
      expect(agentRel.single['target_id'], env.id);
      final taskRow = db.select(
        'SELECT target_environment FROM tasks WHERE id=?',
        ['TSK-bound'],
      );
      expect(taskRow.single['target_environment'], env.id);
      final matchRow = db.select(
        "SELECT id FROM canonical_entities WHERE entity_type='match'",
      );
      expect(matchRow.single['id'], match.id);
      // The match's subject/target relations were reprojected from Git.
      final matchRel = db.select(
        "SELECT relation, target_id FROM entity_relations "
        "WHERE source_type='match' AND source_id=?",
        [match.id],
      );
      final targets = {for (final row in matchRel) row['target_id'] as String};
      expect(targets, containsAll([data.knowledge.id, 'TSK-bound']));
    });
  });

  group('Cross-agent unified memory recall (requirement 3)', () {
    test('recall spans agents, honours supersede, match and security', () {
      final data = seed();
      // Two different agents contribute Knowledge in the same milestone scope.
      final older = entities.create(
        kind: EntityKind.knowledge,
        title: 'Old rate limit',
        body: 'Portal allowed 10 rps.',
        domainId: data.domain.id,
        milestoneId: data.milestone.id,
        extra: {
          'origin': {'kind': 'agent_discovered', 'actor_id': 'AGT-a'},
        },
      );
      final newer = entities.create(
        kind: EntityKind.knowledge,
        title: 'New rate limit',
        body: 'Portal now allows 3 rps.',
        domainId: data.domain.id,
        milestoneId: data.milestone.id,
        extra: {
          'origin': {'kind': 'agent_discovered', 'actor_id': 'AGT-b'},
          'relations': {
            'supports': <String>[],
            'contradicts': <String>[],
            'supersedes': [older.id],
            'derived_from': <String>[],
          },
        },
      );
      // A restricted note that must be filtered out by default.
      entities.create(
        kind: EntityKind.knowledge,
        title: 'Secret',
        body: 'Internal credential rotation note.',
        domainId: data.domain.id,
        milestoneId: data.milestone.id,
        extra: {'visibility': 'restricted'},
      );

      // A trusted issuer both mints and verifies restricted-recall
      // capabilities; the service is wired to verify against exactly this one.
      final issuer = RecallCapabilityIssuer.ephemeral();
      final recall = MemoryRecallService(workspace, capabilityVerifier: issuer);
      final context = const AuthContext(
        repositoryId: 'repo',
        policyVersion: 1,
        environmentId: 'user:jsj',
      );
      final grant = AuthGrant(
        id: 'grant-1',
        repositoryId: 'repo',
        policyVersion: 1,
        environmentId: 'user:jsj',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      final result = recall.recall(milestoneId: data.milestone.id);
      final currentIds = result.current.map((item) => item.id).toSet();
      expect(currentIds, contains(newer.id));
      expect(currentIds, contains(data.knowledge.id));
      // Superseded fact is shadowed but retained for provenance.
      expect(currentIds, isNot(contains(older.id)));
      expect(result.superseded.map((item) => item.id), contains(older.id));
      // Restricted knowledge is filtered by default, included only for an
      // authenticated authorization carrying the restricted scope.
      expect(currentIds.length, 2);
      final authorization = issuer.issue(grant, context);
      expect(
        recall
            .recall(
              milestoneId: data.milestone.id,
              includeRestricted: true,
              authorization: authorization,
            )
            .current
            .length,
        3,
      );
      // Asking for restricted material WITHOUT authorization fails closed.
      expect(
        () => recall.recall(
          milestoneId: data.milestone.id,
          includeRestricted: true,
        ),
        throwsStateError,
      );
      // An authorization lacking the restricted scope is also refused.
      expect(
        () => recall.recall(
          milestoneId: data.milestone.id,
          includeRestricted: true,
          authorization: issuer.issue(grant, context, scopes: const {}),
        ),
        throwsStateError,
      );
      // g2 forge defence: a capability minted by a DIFFERENT issuer (an
      // attacker's secret) fails signature verification and is refused, even
      // though it carries the restricted scope and a live grant.
      final foreignIssuer = RecallCapabilityIssuer.ephemeral();
      final forged = foreignIssuer.issue(grant, context);
      expect(
        () => recall.recall(
          milestoneId: data.milestone.id,
          includeRestricted: true,
          authorization: forged,
        ),
        throwsStateError,
      );
      // g2 expiry defence: an authorization is refused once its grant expiry
      // has passed, even with a valid signature.
      final shortGrant = AuthGrant(
        id: 'grant-2',
        repositoryId: 'repo',
        policyVersion: 1,
        environmentId: 'user:jsj',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      );
      final shortLived = issuer.issue(shortGrant, context);
      expect(
        () => recall.recall(
          milestoneId: data.milestone.id,
          includeRestricted: true,
          authorization: shortLived,
          now: shortGrant.expiresAt.add(const Duration(minutes: 5)),
        ),
        throwsStateError,
      );
      // Recall spans both authoring agents.
      expect(result.contributingActors, containsAll(['AGT-a', 'AGT-b']));

      // An approved match pulls a Knowledge item into a Task scope even when
      // that item was never scoped to the task directly.
      TaskRepository(workspace).create(
        WorkTask(
          id: 'TSK-recall',
          domainId: data.domain.id,
          milestoneId: data.milestone.id,
          title: 'Recall task',
          status: TaskStatus.draft,
          promptDraft: '',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: 'ENV-x',
        ),
      );
      final matches = MatchService(workspace);
      final proposal = matches.propose(
        subjectId: newer.id,
        targetId: 'TSK-recall',
        actorType: 'user',
        actorId: 'user:jsj',
      );
      // Not yet approved -> not recalled by match.
      expect(recall.recall(taskId: 'TSK-recall').current, isEmpty);
      matches.approve(proposal.id, actorType: 'user', actorId: 'user:jsj');
      final byMatch = recall.recall(taskId: 'TSK-recall');
      expect(byMatch.current.single.id, newer.id);
      expect(byMatch.current.single.provenance, startsWith('match:'));
    });
  });

  group('Match validator <-> schema equivalence (gap 5)', () {
    test('rejects bad actor type, confidence>1 and missing agent evidence', () {
      final data = seed();
      final matches = MatchService(workspace);

      // actor_type outside {user, agent} is rejected by the contract validator.
      expect(
        () => matches.propose(
          subjectId: data.knowledge.id,
          targetId: data.milestone.id,
          actorType: 'robot',
          actorId: 'AGT-x',
        ),
        throwsA(isA<ContractViolation>()),
      );

      // confidence must lie within 0..1.
      expect(
        () => matches.propose(
          subjectId: data.knowledge.id,
          targetId: data.milestone.id,
          actorType: 'user',
          actorId: 'user:jsj',
          confidence: 1.5,
        ),
        throwsA(isA<ContractViolation>()),
      );

      // agent/hybrid candidates must carry explainable evidence.
      expect(
        () => matches.propose(
          subjectId: data.knowledge.id,
          targetId: data.milestone.id,
          actorType: 'agent',
          actorId: 'AGT-x',
          mode: 'agent',
          confidence: 0.8,
        ),
        throwsArgumentError,
      );

      // A well-formed match still validates end-to-end.
      final ok = matches.propose(
        subjectId: data.knowledge.id,
        targetId: data.milestone.id,
        actorType: 'agent',
        actorId: 'AGT-x',
        mode: 'agent',
        confidence: 0.8,
        evidence: 'overlap=0.8',
      );
      expect(ok.confidence, 0.8);
    });
  });

  group('Match validator closes actor_type/state/mirror holes (gap g7)', () {
    Map<String, Object?> validMatch() => {
      'schema_version': 1,
      'id': 'MAT-g7',
      'type': 'match',
      'subject': {'kind': 'knowledge', 'id': 'KNW-x'},
      'target': {'kind': 'milestone', 'id': 'MLS-x'},
      'match_mode': 'manual',
      'actor': {'actor_type': 'user', 'actor_id': 'user:jsj'},
      'review_state': 'proposed',
      'knowledge_ids': ['KNW-x'],
      'milestone_id': 'MLS-x',
      'history': [
        {
          'state': 'proposed',
          'action': 'proposed',
          'actor_type': 'user',
          'actor_id': 'user:jsj',
          'at': '2026-07-24T00:00:00Z',
        },
      ],
    };

    CanonicalEntity asEntity(Map<String, Object?> data) =>
        CanonicalEntity(kind: EntityKind.match, id: 'MAT-g7', data: data);

    final validator = WorklogContractValidator();

    test('the baseline hand-built match validates', () {
      validator.validateEntity(asEntity(validMatch()));
    });

    test('g7(a): a history entry without a valid actor_type is rejected', () {
      final data = validMatch();
      ((data['history'] as List).first as Map)['actor_type'] = 'robot';
      expect(
        () => validator.validateEntity(asEntity(data)),
        throwsA(isA<ContractViolation>()),
      );
      // Missing entirely is also rejected.
      final missing = validMatch();
      ((missing['history'] as List).first as Map).remove('actor_type');
      expect(
        () => validator.validateEntity(asEntity(missing)),
        throwsA(isA<ContractViolation>()),
      );
    });

    test('g7(b): review_state must equal the last history state', () {
      final data = validMatch()..['review_state'] = 'approved';
      expect(
        () => validator.validateEntity(asEntity(data)),
        throwsA(isA<ContractViolation>()),
      );
    });

    test('g7(c): subject/target must be mirrored into relation fields', () {
      // Subject not mirrored into knowledge_ids.
      final noSubject = validMatch()..['knowledge_ids'] = <String>[];
      expect(
        () => validator.validateEntity(asEntity(noSubject)),
        throwsA(isA<ContractViolation>()),
      );
      // Target not mirrored into milestone_id.
      final noTarget = validMatch()..remove('milestone_id');
      expect(
        () => validator.validateEntity(asEntity(noTarget)),
        throwsA(isA<ContractViolation>()),
      );
    });
  });

  group('Audit reconstructable from Events alone (gap 6)', () {
    test('match_reviewed Events carry the full correction context', () {
      final data = seed();
      final matches = MatchService(workspace);
      final proposed = matches.propose(
        subjectId: data.knowledge.id,
        targetId: data.milestone.id,
        actorType: 'user',
        actorId: 'user:jsj',
        evidence: 'kickoff notes',
      );
      matches.approve(proposed.id, actorType: 'user', actorId: 'user:reviewer');
      matches.revoke(
        proposed.id,
        actorType: 'user',
        actorId: 'user:jsj',
        reason: 'Wrong milestone.',
      );

      // Reconstruct the audit trail using ONLY the immutable Event stream,
      // never the mutable Match.history.
      final events =
          CanonicalRepository(workspace)
              .list(EntityKind.event)
              .where((event) => event.data['event_type'] == 'match_reviewed')
              .where((event) => event.data['match_id'] == proposed.id)
              .toList()
            ..sort(
              (a, b) => (a.data['occurred_at'] as String).compareTo(
                b.data['occurred_at'] as String,
              ),
            );
      expect(events, hasLength(3));
      expect(events.map((event) => event.data['action']).toList(), [
        'proposed',
        'approve',
        'revoke',
      ]);
      expect(events.map((event) => event.data['review_state']).toList(), [
        'proposed',
        'approved',
        'revoked',
      ]);
      // Every event pins the subject and target so the link is reconstructable.
      for (final event in events) {
        expect((event.data['subject'] as Map)['id'], data.knowledge.id);
        expect((event.data['target'] as Map)['id'], data.milestone.id);
        expect((event.data['actor'] as Map)['actor_id'], isNotEmpty);
      }
      // The correcting transition carries its reason immutably.
      expect(events.last.data['reason'], 'Wrong milestone.');
    });
  });

  group('Recall feeds the execution context pack (gap 7)', () {
    test('approved-match knowledge enters context; restricted is excluded', () {
      final data = seed();
      // Knowledge scoped to a DIFFERENT domain, so only an approved match can
      // pull it into this task's context.
      final otherDomain = entities.create(
        kind: EntityKind.domain,
        title: 'Other',
      );
      final remoteKnowledge = entities.create(
        kind: EntityKind.knowledge,
        title: 'Cross-domain fact',
        body: 'Reusable across domains.',
        domainId: otherDomain.id,
      );
      // Restricted knowledge scoped straight to the task milestone.
      entities.create(
        kind: EntityKind.knowledge,
        title: 'Secret',
        body: 'credential rotation cadence',
        domainId: data.domain.id,
        milestoneId: data.milestone.id,
        extra: {'visibility': 'restricted'},
      );
      TaskRepository(workspace).create(
        WorkTask(
          id: 'TSK-ctx',
          domainId: data.domain.id,
          milestoneId: data.milestone.id,
          title: 'Context task',
          status: TaskStatus.draft,
          promptDraft: '',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: 'ENV-x',
        ),
      );
      final matches = MatchService(workspace);
      final proposal = matches.propose(
        subjectId: remoteKnowledge.id,
        targetId: 'TSK-ctx',
        actorType: 'user',
        actorId: 'user:jsj',
      );
      matches.approve(proposal.id, actorType: 'user', actorId: 'user:jsj');

      final pack = EntityService(workspace).buildExecutionContext('TSK-ctx');
      final entry = pack.entries
          .where((item) => item.id == remoteKnowledge.id)
          .toList();
      // The cross-domain fact is present only via the approved match.
      expect(entry, hasLength(1));
      expect(entry.single.provenance, startsWith('match:'));
      // Restricted material is never bundled into the execution context.
      expect(
        pack.entries.map((item) => item.content).join(),
        isNot(contains('credential rotation cadence')),
      );
    });
  });
}
