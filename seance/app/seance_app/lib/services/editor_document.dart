import 'dart:io';

import 'package:planchette_core/planchette_core.dart' as shared;

const builtInEditorMaximumBytes = shared.textDocumentMaximumBytes;
typedef BuiltInEditorException = shared.TextDocumentException;

/// The managed save folds a CRLF-dominant document's breaks to CRLF and
/// leaves an LF document's alone; the controller's byte preflight must
/// agree with it, so both read this one policy.
shared.TextNormalization seanceSaveNormalization(shared.LineEnding ending) =>
    ending == shared.LineEnding.crlf
    ? shared.TextNormalization.normalize
    : shared.TextNormalization.preserve;

/// Séance's guarded save of a managed copy: the shared writer under Séance's
/// temporary prefix and [seanceSaveNormalization]. Without [expectedSha256]
/// the file's current digest is the baseline.
Future<String> saveBuiltInTextDocument(
  File file,
  String text, {
  bool hasUtf8Bom = false,
  shared.LineEnding lineEnding = shared.LineEnding.lf,
  String? expectedSha256,
  Future<void> Function(File temporary)? observeTemporary,
}) async => shared.saveTextDocument(
  file,
  text,
  hasUtf8Bom: hasUtf8Bom,
  lineEnding: lineEnding,
  normalization: seanceSaveNormalization(lineEnding),
  expectedSha256: expectedSha256 ?? await shared.textDocumentSha256(file),
  temporaryPrefix: '.seance',
  observeTemporary: observeTemporary,
);
