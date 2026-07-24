import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'workspace.dart';

class InstalledRuntimeDescriptor {
  InstalledRuntimeDescriptor({
    required this.id,
    required this.protocol,
    required this.executable,
    required List<String> fixedArguments,
    required Set<String> capabilities,
    required this.executableSha256,
    this.reviewerExecutable,
    List<String> reviewerFixedArguments = const [],
    this.reviewerExecutableSha256,
  }) : fixedArguments = List.unmodifiable(fixedArguments),
       capabilities = Set.unmodifiable(capabilities),
       reviewerFixedArguments = List.unmodifiable(reviewerFixedArguments);

  static const protocolV1 = 'under-claw-json-v1';
  static const allowedCapabilities = {'generate_meta', 'orchestration'};

  final String id;
  final String protocol;
  final String executable;
  final List<String> fixedArguments;
  final Set<String> capabilities;
  final String executableSha256;
  final String? reviewerExecutable;
  final List<String> reviewerFixedArguments;
  final String? reviewerExecutableSha256;

  Map<String, Object?> toJson() => {
    'id': id,
    'protocol': protocol,
    'executable': executable,
    'fixed_arguments': fixedArguments,
    'capabilities': capabilities.toList()..sort(),
    'executable_sha256': executableSha256,
    if (reviewerExecutable != null) 'reviewer_executable': reviewerExecutable,
    if (reviewerFixedArguments.isNotEmpty)
      'reviewer_fixed_arguments': reviewerFixedArguments,
    if (reviewerExecutableSha256 != null)
      'reviewer_executable_sha256': reviewerExecutableSha256,
  };

  factory InstalledRuntimeDescriptor.fromJson(Map<String, Object?> json) {
    const keys = {
      'id',
      'protocol',
      'executable',
      'fixed_arguments',
      'capabilities',
      'executable_sha256',
      'reviewer_executable',
      'reviewer_fixed_arguments',
      'reviewer_executable_sha256',
    };
    if (json.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Unknown runtime descriptor field.');
    }
    final arguments = json['fixed_arguments'];
    final capabilities = json['capabilities'];
    final reviewerArguments = json['reviewer_fixed_arguments'] ?? const [];
    if (arguments is! List ||
        arguments.any((value) => value is! String) ||
        capabilities is! List ||
        capabilities.any((value) => value is! String) ||
        reviewerArguments is! List ||
        reviewerArguments.any((value) => value is! String)) {
      throw const FormatException('Runtime descriptor lists are required.');
    }
    String requiredString(String key) {
      final value = json[key];
      if (value is! String) {
        throw FormatException('Runtime descriptor $key must be a string.');
      }
      return value;
    }

    String? optionalString(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('Runtime descriptor $key must be a string.');
      }
      return value;
    }

    return InstalledRuntimeDescriptor(
      id: requiredString('id'),
      protocol: requiredString('protocol'),
      executable: requiredString('executable'),
      fixedArguments: arguments.cast<String>(),
      capabilities: capabilities.cast<String>().toSet(),
      executableSha256: requiredString('executable_sha256'),
      reviewerExecutable: optionalString('reviewer_executable'),
      reviewerFixedArguments: reviewerArguments.cast<String>(),
      reviewerExecutableSha256: optionalString('reviewer_executable_sha256'),
    );
  }
}

class InstalledRuntimeRegistry {
  InstalledRuntimeRegistry(this.workspace);

  final Workspace workspace;

  File get file => File(p.join(workspace.local.path, 'runtime-adapters.json'));

  List<InstalledRuntimeDescriptor> list() {
    if (!file.existsSync()) return const [];
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map ||
        decoded.keys.any(
          (key) => key != 'schema_version' && key != 'adapters',
        ) ||
        decoded['schema_version'] != 1 ||
        decoded['adapters'] is! List) {
      throw const FormatException('Invalid runtime adapter registry.');
    }
    return (decoded['adapters'] as List)
        .map((value) {
          if (value is! Map) {
            throw const FormatException('Invalid runtime adapter descriptor.');
          }
          return InstalledRuntimeDescriptor.fromJson(
            value.cast<String, Object?>(),
          );
        })
        .toList(growable: false);
  }

  InstalledRuntimeDescriptor require(String id, {required String capability}) {
    final matches = list().where((descriptor) => descriptor.id == id).toList();
    if (matches.length != 1) {
      throw StateError('Installed runtime adapter not found: $id.');
    }
    final descriptor = matches.single;
    validate(descriptor, requiredCapability: capability);
    return descriptor;
  }

  void register(InstalledRuntimeDescriptor descriptor) {
    validate(descriptor);
    final adapters =
        list().where((current) => current.id != descriptor.id).toList()
          ..add(descriptor);
    adapters.sort((left, right) => left.id.compareTo(right.id));
    workspace.ensureLayout();
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'schema_version': 1, 'adapters': adapters.map((item) => item.toJson()).toList()})}\n',
      flush: true,
    );
    temporary.renameSync(file.path);
  }

  void validate(
    InstalledRuntimeDescriptor descriptor, {
    String? requiredCapability,
  }) {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{1,63}$').hasMatch(descriptor.id)) {
      throw const FormatException('Invalid runtime adapter id.');
    }
    if (descriptor.protocol != InstalledRuntimeDescriptor.protocolV1) {
      throw const FormatException('Unsupported runtime adapter protocol.');
    }
    if (!p.isAbsolute(descriptor.executable)) {
      throw const FormatException('Runtime executable path must be absolute.');
    }
    if (descriptor.fixedArguments.any((value) => value.contains('\u0000'))) {
      throw const FormatException('Runtime argument contains a NUL byte.');
    }
    if (descriptor.reviewerFixedArguments.any(
      (value) => value.contains('\u0000'),
    )) {
      throw const FormatException('Reviewer argument contains a NUL byte.');
    }
    if (descriptor.capabilities.isEmpty ||
        descriptor.capabilities.any(
          (value) =>
              !InstalledRuntimeDescriptor.allowedCapabilities.contains(value),
        )) {
      throw const FormatException('Invalid runtime adapter capability.');
    }
    if (requiredCapability != null &&
        !descriptor.capabilities.contains(requiredCapability)) {
      throw StateError(
        'Runtime adapter ${descriptor.id} lacks $requiredCapability.',
      );
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(descriptor.executableSha256)) {
      throw const FormatException('Invalid executable checksum.');
    }
    final executable = File(p.normalize(descriptor.executable));
    if (FileSystemEntity.typeSync(executable.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Runtime executable cannot be a symlink.');
    }
    if (!executable.existsSync()) {
      throw StateError('Runtime executable does not exist.');
    }
    final actual = sha256.convert(executable.readAsBytesSync()).toString();
    if (actual != descriptor.executableSha256) {
      throw StateError('Runtime executable checksum mismatch.');
    }
    if (descriptor.capabilities.contains('orchestration')) {
      final reviewerPath = descriptor.reviewerExecutable;
      final reviewerSha = descriptor.reviewerExecutableSha256;
      if (reviewerPath == null ||
          !p.isAbsolute(reviewerPath) ||
          reviewerSha == null ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(reviewerSha)) {
        throw const FormatException(
          'Orchestration adapters require a verified reviewer executable.',
        );
      }
      final reviewer = File(p.normalize(reviewerPath));
      if (FileSystemEntity.typeSync(reviewer.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('Reviewer executable cannot be a symlink.');
      }
      if (!reviewer.existsSync()) {
        throw StateError('Reviewer executable does not exist.');
      }
      final actualReviewer = sha256
          .convert(reviewer.readAsBytesSync())
          .toString();
      if (actualReviewer != reviewerSha) {
        throw StateError('Reviewer executable checksum mismatch.');
      }
    } else if (descriptor.reviewerExecutable != null ||
        descriptor.reviewerExecutableSha256 != null ||
        descriptor.reviewerFixedArguments.isNotEmpty) {
      throw const FormatException(
        'Reviewer configuration requires orchestration capability.',
      );
    }
  }
}
