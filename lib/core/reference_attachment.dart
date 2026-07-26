import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'canonical_repository.dart';
import 'entity_service.dart';
import 'workspace.dart';

/// Turns a hand-off file into canonical Reference data.
///
/// The content becomes the Reference entity's own Markdown body rather than a
/// pointer to somewhere on this host: a Domain, Milestone, or Task that cites
/// the Reference must read the same bytes from any clone, including a remote
/// agent host. Local paths and credentials therefore never enter the locator.
class ReferenceAttachmentService {
  ReferenceAttachmentService(this.workspace);

  final Workspace workspace;

  /// Attached documents are portable canonical data, so they stay small enough
  /// that cloning the workspace remains cheap. Larger material belongs in its
  /// own repository, referenced through a Repository entity.
  static const maxContentBytes = 256 * 1024;

  CanonicalEntity attach({
    required File file,
    required String title,
    String? domainId,
    String? milestoneId,
    String? taskId,
  }) {
    if (!file.existsSync()) {
      throw StateError('Attachment does not exist: ${file.path}');
    }
    final bytes = file.readAsBytesSync();
    if (bytes.length > maxContentBytes) {
      throw StateError(
        'Attachment exceeds $maxContentBytes bytes: ${bytes.length}.',
      );
    }
    final String content;
    try {
      content = const Utf8Decoder(allowMalformed: false).convert(bytes);
    } on FormatException {
      throw StateError('Attachment must be UTF-8 text.');
    }
    if (content.codeUnits.contains(0)) {
      throw StateError('Attachment must be UTF-8 text.');
    }
    if (content.trim().isEmpty) {
      throw StateError('Attachment is empty.');
    }
    final filename = p.basename(file.path);
    return EntityService(workspace).create(
      kind: EntityKind.reference,
      title: title,
      body: content,
      domainId: domainId,
      milestoneId: milestoneId,
      taskId: taskId,
      extra: {
        'reference_type': 'attached_document',
        // `embedded_document` states the bytes live in this entity's body; the
        // value keeps the original filename for provenance only.
        'locator': {'kind': 'embedded_document', 'value': filename},
        'source_filename': filename,
        'content_sha256': sha256.convert(bytes).toString(),
      },
    );
  }

  /// Returns the attached text, or null when [referenceId] is not an attached
  /// document.
  String? read(String referenceId) {
    final entity = CanonicalRepository(
      workspace,
    ).get(EntityKind.reference, referenceId);
    if (entity == null ||
        entity.data['reference_type'] != 'attached_document') {
      return null;
    }
    return entity.body;
  }
}
