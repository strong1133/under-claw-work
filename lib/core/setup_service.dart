import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'environment_service.dart';
import 'projection.dart';
import 'workspace.dart';

class SetupRequest {
  const SetupRequest({
    required this.localPath,
    required this.environmentName,
    this.privateRemote,
  });

  final String localPath;
  final String environmentName;
  final Uri? privateRemote;
}

class SetupResult {
  const SetupResult({
    required this.workspace,
    required this.environmentId,
    required this.cloned,
  });

  final Workspace workspace;
  final String environmentId;
  final bool cloned;
}

class SetupService {
  Future<SetupResult> setup(SetupRequest request) async {
    if (request.localPath.trim().isEmpty ||
        request.environmentName.trim().isEmpty) {
      throw const FormatException('Local path and environment name required.');
    }
    final root = Directory(p.normalize(p.absolute(request.localPath)));
    var cloned = false;
    if (request.privateRemote case final remote?) {
      _validateRemote(remote);
      if (root.existsSync() && root.listSync().isNotEmpty) {
        throw StateError('Clone destination must be absent or empty.');
      }
      root.parent.createSync(recursive: true);
      await _git(['clone', remote.toString(), root.path], root.parent);
      cloned = true;
    } else {
      root.createSync(recursive: true);
      if (!Directory(p.join(root.path, '.git')).existsSync()) {
        await _git(['init', root.path], root.parent);
      }
    }

    final workspace = Workspace(root)..ensureLayout();
    File(p.join(workspace.local.path, 'setup.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'schema_version': 1, 'workspace_root': root.path, 'clone_owned': cloned})}\n',
      flush: true,
    );
    _ensurePrivateProjectionIgnored(root);
    // Identity is keyed on the immutable machine key, never on the editable
    // alias, so re-running setup on the same host reuses the same ENV id even
    // if the environment has since been renamed.
    final environments = EnvironmentService(workspace);
    final record = environments.register(
      identity: EnvironmentIdentity.detect(workspace),
      alias: request.environmentName,
    );
    final environmentId = record.id;
    final projection = ProjectionStore(workspace);
    try {
      projection.rebuild();
    } finally {
      projection.dispose();
    }
    return SetupResult(
      workspace: workspace,
      environmentId: environmentId,
      cloned: cloned,
    );
  }

  void _validateRemote(Uri remote) {
    if (remote.userInfo.isNotEmpty ||
        remote.queryParameters.keys.any(
          (key) => key.toLowerCase().contains('token'),
        )) {
      throw const FormatException(
        'Credentials must not be embedded in repository URLs.',
      );
    }
    if (remote.scheme != 'https' && remote.scheme != 'ssh') {
      throw const FormatException('Only HTTPS or SSH Git remotes are allowed.');
    }
  }

  Future<void> _git(List<String> arguments, Directory workingDirectory) async {
    final result = await Process.run(
      'git',
      arguments,
      workingDirectory: workingDirectory.path,
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        arguments,
        result.stderr.toString().trim(),
        result.exitCode,
      );
    }
  }

  void _ensurePrivateProjectionIgnored(Directory root) {
    final ignore = File(p.join(root.path, '.gitignore'));
    final existing = ignore.existsSync() ? ignore.readAsStringSync() : '';
    if (!existing.split('\n').contains('.worklog/')) {
      ignore.writeAsStringSync(
        '${existing.isEmpty || existing.endsWith('\n') ? existing : '$existing\n'}.worklog/\n',
        flush: true,
      );
    }
  }
}
