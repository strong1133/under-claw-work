import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'canonical_repository.dart';
import 'workspace.dart';
import 'workspace_file_system.dart';
import 'workspace_mutation_lock.dart';

class HostScopeBinding {
  const HostScopeBinding({
    required this.environmentId,
    this.domainId = '',
    this.milestoneId,
    this.hermesProfile,
    this.discordAccountKey,
    this.repositoryPaths = const {},
    this.mcpCommands = const {},
    this.modelBindings = const {},
  });

  final String environmentId;
  final String domainId;
  final String? milestoneId;
  final String? hermesProfile;
  final String? discordAccountKey;
  final Map<String, String> repositoryPaths;
  final Map<String, List<String>> mcpCommands;
  final Map<String, String> modelBindings;

  String get key => '$environmentId|$domainId|${milestoneId ?? ''}';

  Map<String, Object?> toJson() => {
    'environment_id': environmentId,
    'domain_id': domainId.isEmpty ? null : domainId,
    'milestone_id': ?milestoneId,
    'hermes_profile': ?hermesProfile,
    'discord_account_key': ?discordAccountKey,
    'repository_paths': repositoryPaths,
    'mcp_commands': mcpCommands,
    'model_bindings': modelBindings,
  };

  factory HostScopeBinding.fromJson(Map<String, Object?> json) {
    String requiredString(String key) => switch (json[key]) {
      String value when value.trim().isNotEmpty => value,
      _ => throw FormatException('$key must be a non-empty string.'),
    };
    String? optionalString(String key) => switch (json[key]) {
      null => null,
      String value when value.trim().isNotEmpty => value,
      _ => throw FormatException('$key must be a non-empty string.'),
    };
    Map<String, String> stringMap(Object? value) {
      if (value == null) return const {};
      if (value is! Map ||
          value.keys.any((key) => key is! String) ||
          value.values.any((item) => item is! String)) {
        throw const FormatException(
          'repository_paths must map strings to strings.',
        );
      }
      return value.cast<String, String>();
    }

    Map<String, List<String>> commandMap(Object? value) {
      if (value == null) return const {};
      if (value is! Map || value.keys.any((key) => key is! String)) {
        throw const FormatException('mcp_commands must be a command map.');
      }
      final result = <String, List<String>>{};
      for (final entry in value.entries) {
        final command = entry.value;
        if (command is! List ||
            command.isEmpty ||
            command.any((part) => part is! String)) {
          throw const FormatException(
            'Each MCP command must be a non-empty string list.',
          );
        }
        result[entry.key as String] = command.cast<String>();
      }
      return result;
    }

    return HostScopeBinding(
      environmentId: requiredString('environment_id'),
      domainId: optionalString('domain_id') ?? '',
      milestoneId: optionalString('milestone_id'),
      hermesProfile: optionalString('hermes_profile'),
      discordAccountKey: optionalString('discord_account_key'),
      repositoryPaths: stringMap(json['repository_paths']),
      mcpCommands: commandMap(json['mcp_commands']),
      modelBindings: stringMap(json['model_bindings']),
    );
  }
}

class HostBindingRegistry {
  HostBindingRegistry(this.workspace)
    : repository = CanonicalRepository(workspace);

  final Workspace workspace;
  final CanonicalRepository repository;

  File get file => File('${workspace.local.path}/host-bindings.json');

  List<HostScopeBinding> list() {
    if (!WorkspaceFileSystem.regularFileExists(workspace.root, file)) {
      return const [];
    }
    if (!Platform.isWindows && file.statSync().mode & 0x1ff != 0x180) {
      throw FileSystemException(
        'Host binding registry must have owner-only permissions.',
        file.path,
      );
    }
    final decoded = jsonDecode(
      WorkspaceFileSystem.readText(workspace.root, file),
    );
    if (decoded is! Map ||
        decoded.keys.any(
          (key) => !const {'schema_version', 'bindings'}.contains(key),
        ) ||
        (decoded['schema_version'] != null && decoded['schema_version'] != 1) ||
        decoded['bindings'] is! List) {
      throw const FormatException('Invalid host binding registry.');
    }
    final bindings = decoded['bindings'] as List;
    if (bindings.any((item) => item is! Map)) {
      throw const FormatException('Each host binding must be an object.');
    }
    final parsed = bindings.cast<Map>().map((item) {
      if (item.keys.any(
        (key) => !const {
          'environment_id',
          'domain_id',
          'milestone_id',
          'hermes_profile',
          'discord_account_key',
          'repository_paths',
          'mcp_commands',
          'model_bindings',
        }.contains(key),
      )) {
        throw const FormatException('Host binding contains an unknown field.');
      }
      return HostScopeBinding.fromJson(
        item.map((key, value) => MapEntry(key.toString(), value)),
      );
    }).toList();
    for (final binding in parsed) {
      _validate(binding);
    }
    return parsed;
  }

  HostScopeBinding? resolve({
    required String environmentId,
    required String domainId,
    String? milestoneId,
  }) {
    final candidates = list().where(
      (binding) =>
          binding.environmentId == environmentId &&
          binding.domainId == domainId &&
          (binding.milestoneId == null || binding.milestoneId == milestoneId),
    );
    final exact = candidates.where(
      (binding) => binding.milestoneId == milestoneId,
    );
    return exact.isNotEmpty
        ? exact.single
        : candidates
              .where((binding) => binding.milestoneId == null)
              .singleOrNull;
  }

  Map<String, String> resolveModels({
    required String environmentId,
    required String domainId,
    String? milestoneId,
    required List<String> selectionKeys,
  }) {
    if (selectionKeys.isEmpty) return const {};
    final binding = resolve(
      environmentId: environmentId,
      domainId: domainId,
      milestoneId: milestoneId,
    );
    if (binding == null) {
      throw StateError(
        'No host-local model binding exists for the selected environment.',
      );
    }
    final result = <String, String>{};
    for (final key in selectionKeys) {
      final model = binding.modelBindings[key];
      if (model == null || model.trim().isEmpty) {
        throw StateError('Model selection key is not bound on this host: $key');
      }
      result[key] = model;
    }
    return result;
  }

  void set(HostScopeBinding binding) =>
      WorkspaceMutationLock.runExclusiveSync(workspace, () => _set(binding));

  void _set(HostScopeBinding binding) {
    _validate(binding);
    final bindings = list().toList()
      ..removeWhere((candidate) => candidate.key == binding.key)
      ..add(binding)
      ..sort((left, right) => left.key.compareTo(right.key));
    WorkspaceFileSystem.atomicWriteText(
      workspace.root,
      file,
      '${const JsonEncoder.withIndent('  ').convert({'schema_version': 1, 'bindings': bindings.map((item) => item.toJson()).toList()})}\n',
      ownerOnly: true,
    );
  }

  HostScopeBinding setFromDescriptor(Map<String, Object?> descriptor) {
    _rejectCredentials(descriptor);
    final binding = HostScopeBinding.fromJson(descriptor);
    set(binding);
    return binding;
  }

  void _validate(HostScopeBinding binding) {
    _rejectCredentials(binding.toJson(), r'$');
    for (final entry in binding.mcpCommands.entries) {
      _rejectCredentialArguments(entry.value, r'$.mcp_commands.' + entry.key);
    }
    if (!binding.environmentId.startsWith('ENV-')) {
      throw const FormatException('environment_id must use ENV- prefix.');
    }
    final modelKey = RegExp(r'^[A-Za-z0-9._-]+$');
    for (final entry in binding.modelBindings.entries) {
      if (!modelKey.hasMatch(entry.key) || entry.value.trim().isEmpty) {
        throw const FormatException(
          'Model bindings require portable keys and non-empty runtime models.',
        );
      }
    }
    if (binding.domainId.isEmpty) {
      if (binding.milestoneId != null ||
          binding.repositoryPaths.isNotEmpty ||
          binding.mcpCommands.isNotEmpty) {
        throw const FormatException(
          'Unscoped host bindings may contain only runtime model/profile data.',
        );
      }
      return;
    }
    final domain = repository.get(EntityKind.domain, binding.domainId);
    if (domain == null || domain.data['status'] != 'active') {
      throw StateError('Domain does not exist or is not active.');
    }
    if (binding.milestoneId case final milestoneId?) {
      final milestone = repository.get(EntityKind.milestone, milestoneId);
      if (milestone == null ||
          milestone.data['status'] != 'active' ||
          milestone.data['domain_id'] != binding.domainId) {
        throw StateError('Milestone is not in the configured Domain.');
      }
    }
    if (binding.hermesProfile?.trim().isEmpty == true) {
      throw const FormatException('hermes_profile must not be empty.');
    }
    final allowedRepositoryIds = repository
        .list(EntityKind.project)
        .where(
          (project) =>
              project.data['status'] == 'active' &&
              project.data['domain_id'] == binding.domainId &&
              (project.data['milestone_id'] == null ||
                  project.data['milestone_id'] == binding.milestoneId),
        )
        .expand(
          (project) =>
              (project.data['repository_ids'] as List? ?? const <Object?>[])
                  .whereType<String>(),
        )
        .toSet();
    for (final entry in binding.repositoryPaths.entries) {
      if (!allowedRepositoryIds.contains(entry.key) ||
          repository.get(EntityKind.repository, entry.key) == null) {
        throw StateError(
          'Repository ${entry.key} is not linked to the configured scope.',
        );
      }
      final path = entry.value;
      if (!p.isAbsolute(path)) {
        throw const FormatException(
          'Repository bindings require absolute paths.',
        );
      }
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FormatException(
          'Repository binding paths must be existing real directories.',
        );
      }
    }
    final allowedMcpKeys = repository
        .list(EntityKind.mcpBinding)
        .where(
          (mcp) =>
              mcp.data['status'] == 'active' &&
              mcp.data['domain_id'] == binding.domainId &&
              (mcp.data['milestone_id'] == null ||
                  mcp.data['milestone_id'] == binding.milestoneId),
        )
        .map((mcp) => mcp.data['binding_key'])
        .whereType<String>()
        .toSet();
    for (final entry in binding.mcpCommands.entries) {
      if (!allowedMcpKeys.contains(entry.key)) {
        throw StateError(
          'MCP binding ${entry.key} is not linked to the configured scope.',
        );
      }
      final command = entry.value;
      if (command.isEmpty || command.any((part) => part.trim().isEmpty)) {
        throw const FormatException(
          'MCP commands require non-empty arguments.',
        );
      }
      final executable = command.first;
      if (!p.isAbsolute(executable) ||
          FileSystemEntity.typeSync(executable, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const FormatException(
          'MCP commands require an absolute trusted regular executable.',
        );
      }
    }
  }

  void _rejectCredentialArguments(List<String> arguments, String path) {
    const credentialFlags = {
      '--token',
      '--access-token',
      '--api-key',
      '--apikey',
      '--password',
      '--secret',
      '--client-secret',
      '--credentials',
      '--credential-file',
      '--credentials-file',
      '--token-file',
      '--api-key-file',
    };
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index].trim().toLowerCase();
      if (credentialFlags.contains(argument.split('=').first)) {
        throw FormatException('Credential-bearing argument at $path[$index].');
      }
      if ((argument == '-h' || argument == '--header') &&
          index + 1 < arguments.length &&
          RegExp(
            r'^\s*(authorization|proxy-authorization|cookie|set-cookie)\s*:',
            caseSensitive: false,
          ).hasMatch(arguments[index + 1])) {
        throw FormatException(
          'Credential-bearing header at $path[${index + 1}].',
        );
      }
    }
  }

  void _rejectCredentials(Object? value, [String path = 'descriptor']) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        if (_forbidden.any(key.contains)) {
          throw FormatException(
            '$path.${entry.key} must use a secure-store key.',
          );
        }
        _rejectCredentials(entry.value, '$path.${entry.key}');
      }
    } else if (value is List) {
      for (var index = 0; index < value.length; index++) {
        _rejectCredentials(value[index], '$path[$index]');
      }
    } else if (value is String) {
      final lower = value.toLowerCase();
      final assignment = RegExp(
        r'(^|[^a-z0-9])(?:token|secret|password|credential|authorization|api[_-]?key)\s*[:=]\s*\S+',
      );
      final uri = Uri.tryParse(value);
      if (assignment.hasMatch(lower) ||
          RegExp(r'(^|\s)bearer\s+\S+', caseSensitive: false).hasMatch(value) ||
          (uri != null && uri.hasAuthority && uri.userInfo.isNotEmpty)) {
        throw FormatException('$path must use a secure-store key.');
      }
    }
  }

  static const _forbidden = [
    'token',
    'secret',
    'password',
    'credential',
    'authorization',
    'api_key',
  ];
}
