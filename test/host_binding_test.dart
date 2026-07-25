import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late EntityService entities;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-host-binding-');
    workspace = Workspace(temporary)..ensureLayout();
    entities = EntityService(workspace);
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('host bindings stay local and resolve by environment and scope', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final configurations = ScopeConfigurationService(workspace);
    final repository = configurations.createRepository(
      title: 'Under Claw',
      locatorKind: 'git_remote',
      locatorValue: 'https://example.invalid/under-claw.git',
    );
    configurations.createProject(
      title: 'Control Plane',
      domainId: domain.id,
      repositoryIds: [repository.id],
    );
    configurations.createMcpBinding(
      title: 'Knowledge',
      bindingKey: 'underclaw-knowledge',
      access: 'read',
      domainId: domain.id,
    );
    final checkout = Directory('${workspace.root.path}/checkout')..createSync();
    final registry = HostBindingRegistry(workspace);
    registry.set(
      HostScopeBinding(
        environmentId: 'ENV-remote',
        domainId: domain.id,
        hermesProfile: 'astro-ai',
        repositoryPaths: {repository.id: checkout.path},
        mcpCommands: {
          'underclaw-knowledge': [Platform.resolvedExecutable, 'mcp-serve'],
        },
      ),
    );

    final loaded = registry.resolve(
      environmentId: 'ENV-remote',
      domainId: domain.id,
    );
    expect(loaded?.hermesProfile, 'astro-ai');
    expect(loaded?.repositoryPaths[repository.id], checkout.path);
    expect(
      File('${workspace.local.path}/host-bindings.json').existsSync(),
      isTrue,
    );
    expect(
      Directory('${workspace.workdb.path}/host-bindings').existsSync(),
      isFalse,
    );
  });

  test('host binding descriptors reject embedded credentials', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Company');
    final registry = HostBindingRegistry(workspace);
    expect(
      () => registry.setFromDescriptor({
        'environment_id': 'ENV-company',
        'domain_id': domain.id,
        'hermes_profile': 'company',
        'discord_token': 'must-not-be-stored',
      }),
      throwsFormatException,
    );
  });

  test('host binding descriptors reject credential-bearing string values', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Company');
    ScopeConfigurationService(workspace).createMcpBinding(
      title: 'Knowledge',
      bindingKey: 'underclaw-knowledge',
      access: 'read',
      domainId: domain.id,
    );

    expect(
      () => HostBindingRegistry(workspace).setFromDescriptor({
        'environment_id': 'ENV-company',
        'domain_id': domain.id,
        'mcp_commands': {
          'underclaw-knowledge': [
            '/usr/local/bin/worklog',
            '--token=must-not-be-stored',
          ],
        },
      }),
      throwsFormatException,
    );
  });

  test('host bindings reject relative repository paths', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final configurations = ScopeConfigurationService(workspace);
    final repository = configurations.createRepository(
      title: 'Under Claw',
      locatorKind: 'git_remote',
      locatorValue: 'https://example.invalid/under-claw.git',
    );
    configurations.createProject(
      title: 'Control Plane',
      domainId: domain.id,
      repositoryIds: [repository.id],
    );

    expect(
      () => HostBindingRegistry(workspace).set(
        HostScopeBinding(
          environmentId: 'ENV-remote',
          domainId: domain.id,
          repositoryPaths: {repository.id: 'relative/path'},
        ),
      ),
      throwsFormatException,
    );
  });

  test('host bindings reject repositories outside the canonical scope', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');

    expect(
      () => HostBindingRegistry(workspace).set(
        HostScopeBinding(
          environmentId: 'ENV-remote',
          domainId: domain.id,
          repositoryPaths: const {'REP-missing': '/srv/missing'},
        ),
      ),
      throwsStateError,
    );
  });

  test('host bindings reject MCP commands outside the canonical scope', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');

    expect(
      () => HostBindingRegistry(workspace).set(
        HostScopeBinding(
          environmentId: 'ENV-remote',
          domainId: domain.id,
          mcpCommands: const {
            'unregistered': ['/usr/local/bin/worklog', 'mcp-serve'],
          },
        ),
      ),
      throwsStateError,
    );
  });

  test('host binding descriptors reject non-string scalar fields', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');

    expect(
      () => HostBindingRegistry(workspace).setFromDescriptor({
        'environment_id': 'ENV-remote',
        'domain_id': domain.id,
        'hermes_profile': 123,
      }),
      throwsFormatException,
    );
  });

  test('host binding registry is written with owner-only permissions', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final registry = HostBindingRegistry(workspace);
    registry.set(
      HostScopeBinding(
        environmentId: 'ENV-remote',
        domainId: domain.id,
        hermesProfile: 'astro-ai',
      ),
    );

    expect(registry.file.statSync().mode & 0x1ff, 0x180);
  });

  test('host binding registry rejects insecure existing permissions', () {
    if (Platform.isWindows) return;
    final registry = HostBindingRegistry(workspace);
    registry.file.parent.createSync(recursive: true);
    registry.file.writeAsStringSync('{"bindings":[]}');
    expect(Process.runSync('chmod', ['644', registry.file.path]).exitCode, 0);

    expect(registry.list, throwsA(isA<FileSystemException>()));
  });

  test('archived configuration cannot authorize host bindings', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final configurations = ScopeConfigurationService(workspace);
    final repository = configurations.createRepository(
      title: 'Repository',
      locatorKind: 'git_remote',
      locatorValue: 'https://example.invalid/repository.git',
    );
    final project = configurations.createProject(
      title: 'Archived project',
      domainId: domain.id,
      repositoryIds: [repository.id],
    );
    final mcp = configurations.createMcpBinding(
      title: 'Archived MCP',
      bindingKey: 'archived-mcp',
      access: 'read',
      domainId: domain.id,
    );
    final canonical = CanonicalRepository(workspace);
    for (final entity in [project, mcp]) {
      canonical.update(
        CanonicalEntity(
          kind: entity.kind,
          id: entity.id,
          data: {...entity.data, 'status': 'archived'},
          body: entity.body,
        ),
      );
    }

    expect(
      () => HostBindingRegistry(workspace).set(
        HostScopeBinding(
          environmentId: 'ENV-remote',
          domainId: domain.id,
          repositoryPaths: {repository.id: '/srv/repository'},
          mcpCommands: const {
            'archived-mcp': ['/usr/local/bin/worklog'],
          },
        ),
      ),
      throwsStateError,
    );
  });

  test('existing host registry entries are fully revalidated', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    ScopeConfigurationService(workspace).createMcpBinding(
      title: 'MCP',
      bindingKey: 'knowledge',
      access: 'read',
      domainId: domain.id,
    );
    final registry = HostBindingRegistry(workspace);
    registry.set(
      HostScopeBinding(
        environmentId: 'ENV-remote',
        domainId: domain.id,
        mcpCommands: {
          'knowledge': [Platform.resolvedExecutable],
        },
      ),
    );
    registry.file.writeAsStringSync('''
{"schema_version":1,"bindings":[{"environment_id":"ENV-remote","domain_id":"${domain.id}","mcp_commands":{"knowledge":["/usr/local/bin/worklog","token=not-allowed"]}}]}
''');

    expect(registry.list, throwsFormatException);
  });

  test('host bindings reject split-form credential arguments', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    ScopeConfigurationService(workspace).createMcpBinding(
      title: 'MCP',
      bindingKey: 'knowledge',
      access: 'read',
      domainId: domain.id,
    );
    final registry = HostBindingRegistry(workspace);

    for (final command in <List<String>>[
      ['/usr/bin/server', '--token', 'raw-secret-value'],
      ['/usr/bin/server', '--api-key', 'raw-secret-value'],
      ['/usr/bin/server', '--credentials-file', '/tmp/credentials.json'],
      ['/usr/bin/server', '-H', 'Authorization: Basic raw-secret-value'],
    ]) {
      expect(
        () => registry.set(
          HostScopeBinding(
            environmentId: 'ENV-remote',
            domainId: domain.id,
            mcpCommands: {'knowledge': command},
          ),
        ),
        throwsFormatException,
        reason: command.join(' '),
      );
    }
  });

  test('host registry rejects a symbolic-link local directory', () {
    if (Platform.isWindows) return;
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    workspace.local.deleteSync(recursive: true);
    final external = Directory('${temporary.path}-external-local')
      ..createSync();
    addTearDown(() {
      if (external.existsSync()) external.deleteSync(recursive: true);
    });
    Link(workspace.local.path).createSync(external.path);

    expect(
      () => HostBindingRegistry(
        workspace,
      ).set(HostScopeBinding(environmentId: 'ENV-remote', domainId: domain.id)),
      throwsA(isA<FileSystemException>()),
    );
    expect(external.listSync(), isEmpty);
  });

  test('host bindings require real repository and MCP executable paths', () {
    if (Platform.isWindows) return;
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final configuration = ScopeConfigurationService(workspace);
    final repository = configuration.createRepository(
      title: 'Repository',
      locatorKind: 'git_remote',
      locatorValue: 'https://example.invalid/repository.git',
    );
    configuration.createProject(
      title: 'Project',
      domainId: domain.id,
      repositoryIds: [repository.id],
    );
    configuration.createMcpBinding(
      title: 'MCP',
      bindingKey: 'knowledge',
      access: 'read',
      domainId: domain.id,
    );
    final realDirectory = Directory('${temporary.path}/real')..createSync();
    final linkedDirectory = Link('${temporary.path}/linked-directory')
      ..createSync(realDirectory.path);
    final linkedExecutable = Link('${temporary.path}/linked-executable')
      ..createSync(Platform.resolvedExecutable);
    final registry = HostBindingRegistry(workspace);

    expect(
      () => registry.set(
        HostScopeBinding(
          environmentId: 'ENV-remote',
          domainId: domain.id,
          repositoryPaths: {repository.id: linkedDirectory.path},
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => registry.set(
        HostScopeBinding(
          environmentId: 'ENV-remote',
          domainId: domain.id,
          mcpCommands: {
            'knowledge': [linkedExecutable.path],
          },
        ),
      ),
      throwsFormatException,
    );
  });
}
