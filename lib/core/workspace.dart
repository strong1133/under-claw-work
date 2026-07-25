import 'dart:io';

import 'package:path/path.dart' as p;

import 'workspace_file_system.dart';

class Workspace {
  Workspace(this.root);

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
  File get database => File(p.join(local.path, 'projection.sqlite3'));
  File taskRelations(String taskId) =>
      File(p.join(tasks.path, taskId, 'relations.yaml'));

  void ensureLayout() {
    for (final directory in [
      workdb,
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
      local,
      migrations,
    ]) {
      WorkspaceFileSystem.ensureDirectory(root, directory);
    }
  }
}
