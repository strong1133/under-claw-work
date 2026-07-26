import 'dart:io';

import 'package:path/path.dart' as p;

import 'workspace_file_system.dart';

/// The outcome of checking an existing memory repository against the layout
/// this build of Under Claw Work standardizes on.
class WorkspaceLayoutReport {
  const WorkspaceLayoutReport({
    required this.missingDirectories,
    required this.missingPlaceholders,
    required this.manifestVersion,
  });

  /// Canonical directories that the repository does not contain.
  final List<String> missingDirectories;

  /// Canonical directories present but without the committed placeholder, so a
  /// fresh clone would not reproduce them.
  final List<String> missingPlaceholders;

  /// `null` when the repository predates the layout manifest.
  final int? manifestVersion;

  bool get isVersioned => manifestVersion != null;

  bool get isCurrent => manifestVersion == Workspace.layoutVersion;

  bool get isComplete =>
      missingDirectories.isEmpty && missingPlaceholders.isEmpty && isCurrent;

  /// Stable single-token summary for `worklog doctor`.
  String get status {
    if (missingDirectories.isNotEmpty) return 'incomplete';
    if (!isVersioned) return 'unversioned';
    if (!isCurrent) return 'version_mismatch';
    if (missingPlaceholders.isNotEmpty) return 'not_portable';
    return 'ok';
  }
}

class Workspace {
  Workspace(this.root);

  /// Bumped whenever the standardized directory set changes. A memory
  /// repository records the version it was last normalized to so that a newer
  /// build can tell "never initialized" apart from "initialized by an older
  /// build".
  static const layoutVersion = 1;

  /// Committed placeholder that keeps an otherwise empty canonical directory in
  /// Git. Both readers of [WorkspaceFileSystem.listFiles] filter on canonical
  /// file names, so this file never reaches entity decoding.
  static const placeholderName = '.gitkeep';

  final Directory root;

  Directory get workdb => Directory(p.join(root.path, 'workdb'));
  Directory get tasks => Directory(p.join(workdb.path, 'tasks'));
  Directory get domains => Directory(p.join(workdb.path, 'domains'));
  Directory get milestones => Directory(p.join(workdb.path, 'milestones'));
  Directory get projects => Directory(p.join(workdb.path, 'projects'));
  Directory get repositories => Directory(p.join(workdb.path, 'repositories'));
  Directory get personas => Directory(p.join(workdb.path, 'personas'));
  Directory get agentGroups => Directory(p.join(workdb.path, 'agent-groups'));
  Directory get channelBindings =>
      Directory(p.join(workdb.path, 'channel-bindings'));
  Directory get mcpBindings => Directory(p.join(workdb.path, 'mcp-bindings'));
  Directory get skillPolicies =>
      Directory(p.join(workdb.path, 'skill-policies'));
  Directory get objectives => Directory(p.join(workdb.path, 'objectives'));
  Directory get knowledge => Directory(p.join(workdb.path, 'knowledge'));
  Directory get references => Directory(p.join(workdb.path, 'references'));
  Directory get events => Directory(p.join(workdb.path, 'events'));
  Directory get claims => Directory(p.join(workdb.path, 'claims'));
  Directory get controls => Directory(p.join(workdb.path, 'control-requests'));
  Directory get controlDispositions =>
      Directory(p.join(workdb.path, 'control-dispositions'));
  Directory get runs => Directory(p.join(workdb.path, 'runs'));
  Directory get invocations => Directory(p.join(workdb.path, 'invocations'));
  Directory get matches => Directory(p.join(workdb.path, 'matches'));
  Directory get config => Directory(p.join(workdb.path, 'config'));
  Directory get candidates => Directory(p.join(workdb.path, 'task-candidates'));
  Directory get migrations => Directory(p.join(local.path, 'migrations'));
  Directory get local => Directory(p.join(root.path, '.worklog'));
  Directory get obsidianVault => Directory(p.join(local.path, 'obsidian'));
  File get database => File(p.join(local.path, 'projection.sqlite3'));
  File get layoutManifest => File(p.join(workdb.path, 'workspace.yaml'));
  File taskRelations(String taskId) =>
      File(p.join(tasks.path, taskId, 'relations.yaml'));

  /// Canonical directories that every memory repository standardizes on. These
  /// are versioned data, so each one carries a placeholder and survives clone.
  List<Directory> get canonicalDirectories => [
    tasks,
    domains,
    milestones,
    projects,
    repositories,
    personas,
    agentGroups,
    channelBindings,
    mcpBindings,
    skillPolicies,
    objectives,
    knowledge,
    references,
    events,
    claims,
    controls,
    controlDispositions,
    runs,
    invocations,
    matches,
    config,
    candidates,
  ];

  /// Host-local directories. They are never committed, so they carry no
  /// placeholder and are rebuilt on demand.
  List<Directory> get hostLocalDirectories => [local, migrations];

  void ensureLayout() {
    for (final directory in [
      workdb,
      ...canonicalDirectories,
      ...hostLocalDirectories,
    ]) {
      WorkspaceFileSystem.ensureDirectory(root, directory);
    }
    for (final directory in canonicalDirectories) {
      _ensurePlaceholder(directory);
    }
    _ensureManifest();
    _ensureHostLocalIgnored();
  }

  /// Keeps rebuildable host-local state out of the repository.
  ///
  /// Without this the SQLite projection is committed by the first `git add -A`,
  /// which contradicts the layout contract and leaks one machine's index into
  /// every clone.
  void _ensureHostLocalIgnored() {
    const rule = '.worklog/';
    final ignore = File(p.join(root.path, '.gitignore'));
    final existing = WorkspaceFileSystem.regularFileExists(root, ignore)
        ? WorkspaceFileSystem.readText(root, ignore)
        : '';
    if (existing.split('\n').map((line) => line.trim()).contains(rule)) return;
    final prefix = existing.isEmpty || existing.endsWith('\n')
        ? existing
        : '$existing\n';
    WorkspaceFileSystem.atomicWriteText(root, ignore, '$prefix$rule\n');
  }

  /// Reports the layout without repairing it, so `worklog doctor` can tell the
  /// user what is wrong instead of silently fixing it mid-diagnosis.
  WorkspaceLayoutReport inspectLayout() {
    final missingDirectories = <String>[];
    final missingPlaceholders = <String>[];
    for (final directory in canonicalDirectories) {
      final relative = _relative(directory.path);
      if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        missingDirectories.add(relative);
        continue;
      }
      final placeholder = File(p.join(directory.path, placeholderName));
      if (!WorkspaceFileSystem.regularFileExists(root, placeholder)) {
        missingPlaceholders.add(relative);
      }
    }
    return WorkspaceLayoutReport(
      missingDirectories: missingDirectories,
      missingPlaceholders: missingPlaceholders,
      manifestVersion: _readManifestVersion(),
    );
  }

  String _relative(String path) =>
      p.posix.joinAll(p.split(p.relative(path, from: root.path)));

  void _ensurePlaceholder(Directory directory) {
    final placeholder = File(p.join(directory.path, placeholderName));
    if (WorkspaceFileSystem.regularFileExists(root, placeholder)) return;
    try {
      WorkspaceFileSystem.createTextExclusive(root, placeholder, '');
    } on FileSystemException {
      // Another process seeded the same placeholder first; the goal state
      // is already reached.
    }
  }

  int? _readManifestVersion() {
    if (!WorkspaceFileSystem.regularFileExists(root, layoutManifest)) {
      return null;
    }
    for (final line in WorkspaceFileSystem.readText(
      root,
      layoutManifest,
    ).split('\n')) {
      if (!line.startsWith('layout_version:')) continue;
      return int.tryParse(line.substring('layout_version:'.length).trim());
    }
    return null;
  }

  void _ensureManifest() {
    final content = _manifestContent();
    if (WorkspaceFileSystem.regularFileExists(root, layoutManifest) &&
        WorkspaceFileSystem.readText(root, layoutManifest) == content) {
      return;
    }
    WorkspaceFileSystem.atomicWriteText(root, layoutManifest, content);
  }

  String _manifestContent() {
    final buffer = StringBuffer()
      ..writeln('schema_version: 1')
      ..writeln('type: workspace_layout')
      ..writeln('layout_version: $layoutVersion')
      ..writeln('# Canonical directories standardized by Under Claw Work.')
      ..writeln('# Their contents belong to the repository owner.')
      ..writeln('canonical_directories:');
    for (final directory in canonicalDirectories) {
      buffer.writeln('  - ${_relative(directory.path)}');
    }
    buffer
      ..writeln('# Rebuildable host-local state; never committed.')
      ..writeln('host_local_directories:');
    for (final directory in hostLocalDirectories) {
      buffer.writeln('  - ${_relative(directory.path)}');
    }
    return buffer.toString();
  }
}
