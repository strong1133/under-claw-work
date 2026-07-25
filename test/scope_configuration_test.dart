import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late EntityService entities;
  late ScopeConfigurationService configurations;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-scope-config-');
    workspace = Workspace(temporary)..ensureLayout();
    entities = EntityService(workspace);
    configurations = ScopeConfigurationService(workspace);
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('domain and milestone configuration resolves deterministically', () {
    final domain = entities.create(
      kind: EntityKind.domain,
      title: 'AI-WorkSpace',
    );
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Scoped MCP v1',
      domainId: domain.id,
    );
    final repository = configurations.createRepository(
      title: 'Under Claw Work',
      locatorKind: 'git_remote',
      locatorValue: 'strong1133/under-claw-work',
    );
    final project = configurations.createProject(
      title: 'Under Claw Work',
      domainId: domain.id,
      repositoryIds: [repository.id],
    );
    final orchestrator = configurations.createPersona(
      title: 'AI-WorkSpace Orchestrator',
      body: 'Coordinate implementation and independent review.',
      domainId: domain.id,
    );
    final reviewer = configurations.createPersona(
      title: 'Independent Reviewer',
      body: 'Verify the final tree independently.',
      domainId: domain.id,
    );
    final group = configurations.createAgentGroup(
      title: 'AI-WorkSpace Core',
      domainId: domain.id,
      roles: [
        AgentRole(name: 'orchestrator', personaId: orchestrator.id),
        AgentRole(name: 'reviewer', personaId: reviewer.id, independent: true),
      ],
    );
    final channel = configurations.createChannelBinding(
      title: 'AI-WorkSpace Discord',
      platform: 'discord',
      externalChannelId: 'channel-123',
      domainId: domain.id,
      agentGroupId: group.id,
    );
    final mcp = configurations.createMcpBinding(
      title: 'Under Claw Knowledge',
      bindingKey: 'underclaw-knowledge',
      access: 'read',
      domainId: domain.id,
      milestoneId: milestone.id,
    );
    final skillPolicy = configurations.createSkillPolicy(
      title: 'Governed execution',
      orderedSkillIds: const [
        'under-claw-meta-prompt',
        'under-claw-jarvis-plan-loop',
      ],
      perRoundSkillId: 'under-claw-jarvis-plan',
      domainId: domain.id,
    );

    final resolved = ScopeContextResolver(workspace).resolve(
      domainId: domain.id,
      milestoneId: milestone.id,
      externalChannelId: 'channel-123',
    );

    expect(resolved.domain.id, domain.id);
    expect(resolved.milestone?.id, milestone.id);
    expect(resolved.projects.map((item) => item.id), [project.id]);
    expect(resolved.repositories.map((item) => item.id), [repository.id]);
    expect(resolved.personas.map((item) => item.id), [
      orchestrator.id,
      reviewer.id,
    ]);
    expect(resolved.agentGroups.map((item) => item.id), [group.id]);
    expect(resolved.channelBinding?.id, channel.id);
    expect(resolved.mcpBindings.map((item) => item.id), [mcp.id]);
    expect(resolved.skillPolicies.map((item) => item.id), [skillPolicy.id]);
  });

  test('portable configuration rejects local paths and credentials', () {
    expect(
      () => configurations.createRepository(
        title: 'Unsafe repository',
        locatorKind: 'local_path',
        locatorValue: '/private/company/repository',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => configurations.createMcpBinding(
        title: 'Unsafe MCP',
        bindingKey: 'company-api',
        access: 'read',
        domainId: 'DOM-missing',
        extra: const {'token': 'secret-value'},
      ),
      throwsA(anyOf(isA<FormatException>(), isA<ContractViolation>())),
    );
    expect(
      () => configurations.createRepository(
        title: 'Credential-bearing remote',
        locatorKind: 'git_remote',
        locatorValue: 'https://user:token@example.invalid/repository.git',
      ),
      throwsFormatException,
    );
    expect(
      () => configurations.createRepository(
        title: 'Windows local path',
        locatorKind: 'git_remote',
        locatorValue: r'C:\Users\me\repository',
      ),
      throwsFormatException,
    );
  });

  test('portable descriptors create configuration without host secrets', () {
    final domain = entities.create(
      kind: EntityKind.domain,
      title: 'Company Product',
    );
    final persona = configurations.createFromDescriptor(EntityKind.persona, {
      'title': 'Product Orchestrator',
      'body': 'Coordinate product work.',
      'domain_id': domain.id,
    });
    final mcp = configurations.createFromDescriptor(EntityKind.mcpBinding, {
      'title': 'Product Knowledge',
      'binding_key': 'company-product-knowledge',
      'access': 'read',
      'domain_id': domain.id,
    });

    expect(persona.kind, EntityKind.persona);
    expect(persona.body, 'Coordinate product work.');
    expect(mcp.data['binding_key'], 'company-product-knowledge');
  });

  test('milestone skill policy deterministically overrides domain policy', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Game');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'D4 Season',
      domainId: domain.id,
    );
    final domainPolicy = configurations.createSkillPolicy(
      title: 'Game default',
      orderedSkillIds: const ['under-claw-meta-prompt'],
      domainId: domain.id,
    );
    final milestonePolicy = configurations.createSkillPolicy(
      title: 'D4 execution',
      orderedSkillIds: const ['under-claw-jarvis-plan-loop'],
      domainId: domain.id,
      milestoneId: milestone.id,
    );

    final domainContext = ScopeContextResolver(
      workspace,
    ).resolve(domainId: domain.id);
    final milestoneContext = ScopeContextResolver(
      workspace,
    ).resolve(domainId: domain.id, milestoneId: milestone.id);

    expect(domainContext.selectedSkillPolicy?.id, domainPolicy.id);
    expect(milestoneContext.selectedSkillPolicy?.id, milestonePolicy.id);
    expect(
      milestoneContext.toJson()['selected_skill_policy'],
      milestonePolicy.data,
    );
    expect(
      () => configurations.createSkillPolicy(
        title: 'Ambiguous duplicate',
        orderedSkillIds: const ['under-claw-meta-prompt'],
        domainId: domain.id,
        milestoneId: milestone.id,
      ),
      throwsStateError,
    );
  });

  test('milestone MCP binding overrides the matching Domain binding key', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Release',
      domainId: domain.id,
    );
    configurations.createMcpBinding(
      title: 'Domain knowledge',
      bindingKey: 'knowledge',
      access: 'read',
      domainId: domain.id,
    );
    final inherited = configurations.createMcpBinding(
      title: 'Domain search',
      bindingKey: 'search',
      access: 'read',
      domainId: domain.id,
    );
    final override = configurations.createMcpBinding(
      title: 'Release knowledge',
      bindingKey: 'knowledge',
      access: 'read_write',
      domainId: domain.id,
      milestoneId: milestone.id,
    );

    final resolved = ScopeContextResolver(
      workspace,
    ).resolve(domainId: domain.id, milestoneId: milestone.id);

    expect(resolved.mcpBindings.map((item) => item.id).toSet(), {
      inherited.id,
      override.id,
    });
  });

  test('extension data cannot override canonical or required fields', () {
    final repository = configurations.createRepository(
      title: 'Safe repository',
      locatorKind: 'git_remote',
      locatorValue: 'ssh://git@example.invalid/safe/repository.git',
      extra: {
        'schema_version': 999,
        'id': 'REP-forged',
        'type': 'domain',
        'status': 'archived',
        'scope': {'domain_id': 'DOM-forged'},
        'locator': {'kind': 'git_remote', 'value': 'forged'},
      },
    );

    expect(repository.data['schema_version'], 1);
    expect(repository.data['id'], repository.id);
    expect(repository.data['type'], 'repository');
    expect(repository.data['status'], 'active');
    expect(repository.data.containsKey('scope'), isFalse);
    expect(repository.data['locator'], {
      'kind': 'git_remote',
      'value': 'ssh://git@example.invalid/safe/repository.git',
    });
  });

  test('repository validation rejects ambiguous policy scopes', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Finance');
    final policy = configurations.createSkillPolicy(
      title: 'Finance policy',
      orderedSkillIds: const ['under-claw-meta-prompt'],
      domainId: domain.id,
    );
    final duplicateId = newId(EntityKind.skillPolicy.prefix);
    configurations.repository.create(
      CanonicalEntity(
        kind: EntityKind.skillPolicy,
        id: duplicateId,
        data: {...policy.data, 'id': duplicateId},
      ),
    );

    expect(
      () => WorklogContractValidator().validateRepository(
        configurations.repository,
        const [],
      ),
      throwsA(isA<ContractViolation>()),
    );
  });

  test('canonical ids cannot escape their entity directory', () {
    final escaped = File('${temporary.parent.path}/escaped-review.md');
    if (escaped.existsSync()) escaped.deleteSync();
    const maliciousId = 'PER-/../../../../escaped-review';

    expect(
      () => CanonicalRepository(workspace).create(
        const CanonicalEntity(
          kind: EntityKind.persona,
          id: maliciousId,
          data: {
            'schema_version': 1,
            'id': maliciousId,
            'type': 'persona',
            'title': 'Traversal',
            'status': 'active',
          },
        ),
      ),
      throwsFormatException,
    );
    expect(escaped.existsSync(), isFalse);
  });

  test('channel binding rejects an agent group from another scope', () {
    final domainA = entities.create(kind: EntityKind.domain, title: 'A');
    final domainB = entities.create(kind: EntityKind.domain, title: 'B');
    final personaB = configurations.createPersona(
      title: 'B persona',
      body: 'B only',
      domainId: domainB.id,
    );
    final groupB = configurations.createAgentGroup(
      title: 'B group',
      domainId: domainB.id,
      roles: [AgentRole(name: 'orchestrator', personaId: personaB.id)],
    );

    expect(
      () => configurations.createChannelBinding(
        title: 'A channel',
        platform: 'discord',
        externalChannelId: 'channel-a',
        domainId: domainA.id,
        agentGroupId: groupB.id,
      ),
      throwsFormatException,
    );
  });

  test(
    'canonical reads reject a document id that differs from its filename',
    () {
      final file = File('${workspace.personas.path}/PER-file.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('''
---
{"schema_version":1,"id":"PER-document","type":"persona","title":"Mismatch","status":"active"}
---
body
''');
      expect(file.existsSync(), isTrue);

      expect(
        () =>
            CanonicalRepository(workspace).get(EntityKind.persona, 'PER-file'),
        throwsFormatException,
      );
    },
  );

  test('canonical reads enforce the runtime entity contract', () {
    File('${workspace.personas.path}/PER-invalid.md')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
---
{"schema_version":1,"id":"PER-invalid","type":"persona","title":"Invalid","status":"unknown"}
---
body
''');

    expect(
      () =>
          CanonicalRepository(workspace).get(EntityKind.persona, 'PER-invalid'),
      throwsA(isA<ContractViolation>()),
    );
  });

  test('scope configuration rejects a milestone from another domain', () {
    final domainA = entities.create(kind: EntityKind.domain, title: 'A');
    final domainB = entities.create(kind: EntityKind.domain, title: 'B');
    final milestoneB = entities.create(
      kind: EntityKind.milestone,
      title: 'B1',
      domainId: domainB.id,
    );

    expect(
      () => configurations.createMcpBinding(
        title: 'Wrong scope',
        bindingKey: 'wrong-scope',
        access: 'read',
        domainId: domainA.id,
        milestoneId: milestoneB.id,
      ),
      throwsFormatException,
    );
  });

  test('resolver rejects archived Domain and Milestone anchors', () {
    final repository = CanonicalRepository(workspace);
    final resolver = ScopeContextResolver(workspace);
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Milestone',
      domainId: domain.id,
    );

    repository.update(
      CanonicalEntity(
        kind: milestone.kind,
        id: milestone.id,
        data: {...milestone.data, 'status': 'archived'},
        body: milestone.body,
      ),
    );
    expect(
      () => resolver.resolve(domainId: domain.id, milestoneId: milestone.id),
      throwsStateError,
    );

    repository.update(
      CanonicalEntity(
        kind: milestone.kind,
        id: milestone.id,
        data: {...milestone.data, 'status': 'active'},
        body: milestone.body,
      ),
    );
    repository.update(
      CanonicalEntity(
        kind: domain.kind,
        id: domain.id,
        data: {...domain.data, 'status': 'archived'},
        body: domain.body,
      ),
    );
    expect(
      () => resolver.resolve(domainId: domain.id, milestoneId: milestone.id),
      throwsStateError,
    );
  });

  test('archived configuration is ignored and can be replaced', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final archived = configurations.createSkillPolicy(
      title: 'Old policy',
      domainId: domain.id,
      orderedSkillIds: const ['old-skill'],
    );
    final repository = CanonicalRepository(workspace);
    repository.update(
      CanonicalEntity(
        kind: archived.kind,
        id: archived.id,
        data: {...archived.data, 'status': 'archived'},
        body: archived.body,
      ),
    );

    final replacement = configurations.createSkillPolicy(
      title: 'New policy',
      domainId: domain.id,
      orderedSkillIds: const ['new-skill'],
    );
    final resolved = ScopeContextResolver(
      workspace,
    ).resolve(domainId: domain.id);

    expect(resolved.skillPolicies.map((item) => item.id), [replacement.id]);
    expect(resolved.selectedSkillPolicy?.id, replacement.id);
    expect(
      () => WorklogContractValidator().validateRepository(
        CanonicalRepository(workspace),
        const [],
      ),
      returnsNormally,
    );
  });

  test('Persona descriptors require an explicit Domain scope', () {
    expect(
      () => configurations.createFromDescriptor(EntityKind.persona, {
        'title': 'Unscoped persona',
        'body': 'Must not become globally visible.',
      }),
      throwsFormatException,
    );
  });

  test('descriptor parsing rejects malformed list elements', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final persona = configurations.createPersona(
      title: 'Persona',
      body: 'Body',
      domainId: domain.id,
    );

    expect(
      () => configurations.createFromDescriptor(EntityKind.agentGroup, {
        'title': 'Malformed group',
        'domain_id': domain.id,
        'roles': [
          {'name': 'valid', 'persona_id': persona.id},
          'silently-dropped-before',
        ],
      }),
      throwsFormatException,
    );
    expect(CanonicalRepository(workspace).list(EntityKind.agentGroup), isEmpty);
  });

  test('resolver accepts schema-valid top-level-only scope metadata', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    File('${workspace.personas.path}/PER-top-level.md')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
---
{"schema_version":1,"id":"PER-top-level","type":"persona","title":"Top Level","status":"active","domain_id":"${domain.id}"}
---
Portable persona body.
''');

    final resolved = ScopeContextResolver(
      workspace,
    ).resolve(domainId: domain.id);

    expect(resolved.personas.map((item) => item.id), contains('PER-top-level'));
  });

  test('canonical reads reject conflicting top-level and nested scope', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final other = entities.create(kind: EntityKind.domain, title: 'Other');
    File('${workspace.personas.path}/PER-conflicting.md')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
---
{"schema_version":1,"id":"PER-conflicting","type":"persona","title":"Conflicting","status":"active","domain_id":"${domain.id}","scope":{"domain_id":"${other.id}"}}
---
Conflicting persona body.
''');

    expect(
      () => CanonicalRepository(workspace).list(EntityKind.persona),
      throwsA(isA<ContractViolation>()),
    );
  });

  test('top-level-only scope participates in active policy uniqueness', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    File('${workspace.skillPolicies.path}/SKP-top-level.md')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
---
{"schema_version":1,"id":"SKP-top-level","type":"skill_policy","title":"Existing","status":"active","domain_id":"${domain.id}","ordered_skill_ids":["existing"]}
---
''');

    expect(
      () => configurations.createSkillPolicy(
        title: 'Duplicate',
        orderedSkillIds: const ['duplicate'],
        domainId: domain.id,
      ),
      throwsStateError,
    );
  });
}
