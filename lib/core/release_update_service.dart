import 'dart:io';

import 'package:path/path.dart' as p;

class ReleaseUpdateStatus {
  const ReleaseUpdateStatus({
    required this.currentVersion,
    required this.candidateVersion,
  });

  final String currentVersion;
  final String candidateVersion;

  bool get updateAvailable => currentVersion != candidateVersion;
}

class ReleaseUpdateService {
  ReleaseUpdateService({Directory? installRoot})
    : installRoot = installRoot ?? Directory(_defaultInstallRoot());

  final Directory installRoot;

  Future<ReleaseUpdateStatus> check(Directory release) async {
    _requireAbsolute(release);
    final manifest = File(p.join(release.path, 'release-manifest.tsv'));
    final verifier = File(
      p.join(installRoot.path, 'packaging', 'verify-release.sh'),
    );
    final candidateVersionFile = File(
      p.join(release.path, 'RELEASE-VERSION.txt'),
    );
    final currentVersionFile = File(
      p.join(installRoot.path, 'RELEASE-VERSION.txt'),
    );
    if (!manifest.existsSync() ||
        !verifier.existsSync() ||
        !candidateVersionFile.existsSync()) {
      throw StateError('Release or trusted installed verifier is incomplete.');
    }
    final verified = await Process.run('bash', [
      _bashPath(verifier.path),
      _bashPath(release.path),
    ], runInShell: false);
    if (verified.exitCode != 0) {
      throw StateError('Release manifest verification failed.');
    }
    return ReleaseUpdateStatus(
      currentVersion: currentVersionFile.existsSync()
          ? currentVersionFile.readAsStringSync().trim()
          : 'unknown',
      candidateVersion: candidateVersionFile.readAsStringSync().trim(),
    );
  }

  Future<String> apply(Directory release) async {
    await check(release);
    return _runInstalledHelper('update.sh', [release.path]);
  }

  Future<String> rollback() => _runInstalledHelper('rollback.sh', const []);

  Future<String> _runInstalledHelper(
    String name,
    List<String> arguments,
  ) async {
    final helper = File(p.join(installRoot.path, 'packaging', name));
    if (!helper.existsSync()) {
      throw StateError('Installed update helper is unavailable: $name');
    }
    final result = await Process.run(
      'bash',
      [_bashPath(helper.path), ...arguments.map(_bashPath)],
      environment: {
        ...Platform.environment,
        'UNDER_CLAW_WORK_HOME': _bashPath(installRoot.path),
      },
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw StateError(
        '$name failed without changing the active installation.',
      );
    }
    return result.stdout.toString().trim();
  }

  String _bashPath(String value) {
    if (!Platform.isWindows) return value;
    final normalized = value.replaceAll(r'\', '/');
    final drivePath = RegExp(r'^([A-Za-z]):/(.*)$').firstMatch(normalized);
    if (drivePath != null) {
      return '/${drivePath.group(1)!.toLowerCase()}/${drivePath.group(2)!}';
    }
    return normalized;
  }

  void _requireAbsolute(Directory release) {
    if (!p.isAbsolute(release.path) || !release.existsSync()) {
      throw const FormatException(
        'Release must be an existing absolute directory.',
      );
    }
  }

  static String _defaultInstallRoot() {
    final configured = Platform.environment['UNDER_CLAW_WORK_HOME'];
    if (configured != null && configured.isNotEmpty) return configured;
    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'under-claw-work');
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('HOME is unavailable.');
    }
    return p.join(home, '.local', 'share', 'under-claw-work');
  }
}
