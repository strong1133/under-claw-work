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
  ReleaseUpdateService({Directory? installRoot, this.windowsGitBashRoot})
    : installRoot = installRoot ?? Directory(_defaultInstallRoot());

  final Directory installRoot;
  final Directory? windowsGitBashRoot;
  _GitBashTools? _gitBashToolsCache;

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
    final verifierPath = await _bashPath(verifier.path);
    final releasePath = await _bashPath(release.path);
    final verified = await Process.run(await _bashExecutable(), [
      verifierPath,
      releasePath,
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
    final helperPath = await _bashPath(helper.path);
    final bashArguments = <String>[];
    for (final argument in arguments) {
      bashArguments.add(await _bashPath(argument));
    }
    final bashInstallRoot = await _bashPath(installRoot.path);
    final result = await Process.run(
      await _bashExecutable(),
      [helperPath, ...bashArguments],
      environment: {
        ...Platform.environment,
        'UNDER_CLAW_WORK_HOME': bashInstallRoot,
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

  Future<String> _bashPath(String value) async {
    if (!Platform.isWindows) return value;
    final tools = await _gitBashTools();
    final converted = await Process.run(tools.cygpath, [
      '-a',
      '-u',
      '--',
      value,
    ], runInShell: false);
    final output = converted.stdout.toString().trim();
    if (converted.exitCode != 0 || !output.startsWith('/')) {
      throw StateError('Unable to convert a Windows path for Git Bash.');
    }
    return output;
  }

  Future<String> _bashExecutable() async =>
      Platform.isWindows ? (await _gitBashTools()).bash : 'bash';

  Future<_GitBashTools> _gitBashTools() async {
    final cached = _gitBashToolsCache;
    if (cached != null) return cached;
    final candidates = windowsGitBashRoot == null
        ? <Directory>[
            Directory(r'C:\Program Files\Git'),
            Directory(r'C:\Program Files (x86)\Git'),
          ]
        : <Directory>[windowsGitBashRoot!];
    for (final candidate in candidates) {
      if (!p.isAbsolute(candidate.path) || !candidate.existsSync()) continue;
      final gitRoot = candidate.resolveSymbolicLinksSync();
      final bash = File(p.join(gitRoot, 'bin', 'bash.exe'));
      final cygpath = File(p.join(gitRoot, 'usr', 'bin', 'cygpath.exe'));
      if (!bash.existsSync() || !cygpath.existsSync()) continue;
      return _gitBashToolsCache = _GitBashTools(
        bash: bash.resolveSymbolicLinksSync(),
        cygpath: cygpath.resolveSymbolicLinksSync(),
      );
    }
    throw StateError('Git Bash tools are unavailable for release operations.');
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

class _GitBashTools {
  const _GitBashTools({required this.bash, required this.cygpath});

  final String bash;
  final String cygpath;
}
