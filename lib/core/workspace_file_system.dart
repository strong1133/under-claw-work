import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Fail-closed filesystem operations for data below a user-selected workspace.
///
/// The workspace root itself may be a deliberate symlink. Every component below
/// it must be a real directory or regular file; canonical and host-local data
/// never follow repository-controlled links.
class WorkspaceFileSystem {
  const WorkspaceFileSystem._();

  static void ensureDirectory(Directory root, Directory target) {
    if (!root.existsSync()) root.createSync(recursive: true);
    final rootPath = p.normalize(p.absolute(root.path));
    final targetPath = _inside(rootPath, target.path);
    var current = rootPath;
    for (final component in p.split(p.relative(targetPath, from: rootPath))) {
      if (component == '.') continue;
      current = p.join(current, component);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        Directory(current).createSync();
      } else if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Workspace directory path must not contain links or files.',
          current,
        );
      }
    }
  }

  static bool regularFileExists(Directory root, File file) {
    final path = _inside(p.normalize(p.absolute(root.path)), file.path);
    if (!_parentsSafe(root, path)) return false;
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Workspace file must be a regular file and not a link.',
        path,
      );
    }
    return true;
  }

  static String readText(Directory root, File file) {
    if (!regularFileExists(root, file)) {
      throw FileSystemException('Workspace file does not exist.', file.path);
    }
    final handle = file.openSync(mode: FileMode.read);
    late final List<int> bytes;
    try {
      bytes = handle.readSync(handle.lengthSync());
    } finally {
      handle.closeSync();
    }
    if (!regularFileExists(root, file)) {
      throw FileSystemException(
        'Workspace file changed while reading.',
        file.path,
      );
    }
    return utf8.decode(bytes);
  }

  static List<File> listFiles(
    Directory root,
    Directory directory, {
    bool recursive = true,
  }) {
    final path = _inside(p.normalize(p.absolute(root.path)), directory.path);
    if (!_parentsSafe(root, path)) return const [];
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return const [];
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Workspace list root must be a real directory.',
        path,
      );
    }
    final result = <File>[];
    for (final entity in directory.listSync(
      recursive: recursive,
      followLinks: false,
    )) {
      final entityType = FileSystemEntity.typeSync(
        entity.path,
        followLinks: false,
      );
      if (entityType == FileSystemEntityType.link) {
        throw FileSystemException(
          'Workspace data must not contain symbolic links.',
          entity.path,
        );
      }
      if (entityType == FileSystemEntityType.file) {
        result.add(File(entity.path));
      }
    }
    return result;
  }

  static void createTextExclusive(Directory root, File file, String content) {
    ensureDirectory(root, file.parent);
    if (regularFileExists(root, file)) {
      throw FileSystemException('Workspace file already exists.', file.path);
    }
    file.createSync(exclusive: true);
    final handle = file.openSync(mode: FileMode.writeOnly);
    try {
      handle.writeStringSync(content);
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
  }

  static void atomicWriteText(
    Directory root,
    File file,
    String content, {
    bool ownerOnly = false,
  }) {
    ensureDirectory(root, file.parent);
    final existed = regularFileExists(root, file);
    final random = Random.secure();
    final temporary = File(
      '${file.path}.tmp.$pid.${random.nextInt(0x7fffffff)}',
    );
    temporary.createSync(exclusive: true);
    final handle = temporary.openSync(mode: FileMode.writeOnly);
    try {
      handle.writeStringSync(content);
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    try {
      if (ownerOnly && !Platform.isWindows) {
        final result = Process.runSync('chmod', ['600', temporary.path]);
        if (result.exitCode != 0) {
          throw FileSystemException(
            'Unable to secure workspace-local file permissions.',
            temporary.path,
          );
        }
      }
      if (existed && !regularFileExists(root, file)) {
        throw FileSystemException('Workspace target changed.', file.path);
      }
      if (!existed &&
          FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw FileSystemException('Workspace target appeared.', file.path);
      }
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  static void deleteFile(Directory root, File file) {
    if (!regularFileExists(root, file)) {
      throw FileSystemException('Workspace file does not exist.', file.path);
    }
    file.deleteSync();
  }

  static bool _parentsSafe(Directory root, String targetPath) {
    final rootPath = p.normalize(p.absolute(root.path));
    final target = _inside(rootPath, targetPath);
    var current = rootPath;
    final parts = p.split(p.relative(target, from: rootPath));
    for (var index = 0; index < parts.length - 1; index++) {
      current = p.join(current, parts[index]);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) return false;
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Workspace path must not contain symbolic links.',
          current,
        );
      }
    }
    return true;
  }

  static String _inside(String rootPath, String targetPath) {
    final target = p.normalize(p.absolute(targetPath));
    if (target != rootPath && !p.isWithin(rootPath, target)) {
      throw FileSystemException('Path escapes workspace root.', target);
    }
    return target;
  }
}
