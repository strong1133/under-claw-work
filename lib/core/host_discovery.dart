import 'dart:io';

import 'package:path/path.dart' as p;

enum AgentHost { hermes, claudeCode, codex }

class AgentHostStatus {
  const AgentHostStatus({
    required this.host,
    required this.home,
    required this.detected,
    required this.connected,
  });

  final AgentHost host;
  final Directory home;
  final bool detected;
  final bool connected;

  String get id => switch (host) {
    AgentHost.hermes => 'hermes',
    AgentHost.claudeCode => 'claude-code',
    AgentHost.codex => 'codex',
  };
}

class HostDiscoveryService {
  HostDiscoveryService({
    String? userHome,
    Map<String, String>? environment,
    bool Function(String executable)? executableExists,
  }) : _userHome = userHome ?? _defaultHome(),
       _environment = environment ?? Platform.environment,
       _executableExists = executableExists ?? _commandExists;

  final String _userHome;
  final Map<String, String> _environment;
  final bool Function(String executable) _executableExists;

  List<AgentHostStatus> discover() => [
    _status(
      AgentHost.hermes,
      'hermes',
      _environment['HERMES_HOME'] ?? p.join(_userHome, '.hermes'),
      enabled: _environment['UNDER_CLAW_EXPERIMENTAL_HERMES'] == '1',
    ),
    _status(
      AgentHost.claudeCode,
      'claude',
      _environment['CLAUDE_HOME'] ?? p.join(_userHome, '.claude'),
    ),
    _status(
      AgentHost.codex,
      'codex',
      _environment['CODEX_HOME'] ?? p.join(_userHome, '.codex'),
    ),
  ];

  AgentHostStatus _status(
    AgentHost host,
    String executable,
    String homePath, {
    bool enabled = true,
  }) {
    final home = Directory(p.normalize(p.absolute(homePath)));
    final detected =
        enabled && (home.existsSync() || _executableExists(executable));
    return AgentHostStatus(
      host: host,
      home: home,
      detected: detected,
      connected:
          detected &&
          Directory(
            p.join(home.path, 'skills', 'under-claw-work-plan'),
          ).existsSync(),
    );
  }

  static String _defaultHome() {
    final environment = Platform.environment;
    return environment['HOME'] ??
        environment['USERPROFILE'] ??
        Directory.current.path;
  }

  static bool _commandExists(String executable) {
    final path = Platform.environment['PATH'];
    if (path == null) return false;
    final extensions = Platform.isWindows
        ? (Platform.environment['PATHEXT'] ?? '.EXE;.BAT;.CMD')
              .split(';')
              .where((value) => value.isNotEmpty)
        : const [''];
    for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
      if (directory.isEmpty) continue;
      for (final extension in extensions) {
        if (File(p.join(directory, '$executable$extension')).existsSync()) {
          return true;
        }
      }
    }
    return false;
  }
}
