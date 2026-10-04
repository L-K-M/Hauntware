import 'dart:async';
import 'dart:io';

import 'package:planchette_core/planchette_core.dart' as shared;

export 'package:planchette_core/planchette_core.dart' show LineEnding;

/// Compatibility names keep checkout callers stable while document mechanics
/// live in the editor package shared with Planchette and Séance.
const int builtInEditorMaximumBytes = shared.textDocumentMaximumBytes;
typedef BuiltInTextDocument = shared.TextDocument;
typedef BuiltInEditorException = shared.TextDocumentException;

/// Machine-readable load failures for hosts that localize editor errors.
enum BuiltInTextDocumentFailure { invalidUtf8, binary, changed, missing, other }

const _invalidUtf8Message = 'This file is not valid UTF-8 text.';
const _binaryMessage = 'This file appears to be binary, not editable text.';
const _changedMessage = 'The local copy changed while it was being opened.';
const _missingMessage = 'The file no longer exists.';
const _missingOrNonregularMessage =
    'The local copy is missing or no longer a regular file.';

/// Adapts Planchette's stable message contract to a localized host enum.
BuiltInTextDocumentFailure classifyBuiltInTextDocumentFailure(
  BuiltInEditorException error,
) => switch (error.message) {
  _invalidUtf8Message => BuiltInTextDocumentFailure.invalidUtf8,
  _binaryMessage => BuiltInTextDocumentFailure.binary,
  _changedMessage => BuiltInTextDocumentFailure.changed,
  _missingMessage ||
  _missingOrNonregularMessage => BuiltInTextDocumentFailure.missing,
  _ => BuiltInTextDocumentFailure.other,
};

/// A managed download exceeded its caller's cap before opening the editor.
final class CheckoutLimitException implements Exception {
  const CheckoutLimitException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// User-selected local links resolve once. Managed checkouts never call this:
/// they use the shared loader's regular-file-only policy.
Future<File> resolveBuiltInEditorTarget(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    return File(await file.resolveSymbolicLinks());
  }
  return file;
}

Future<String> loadBuiltInTextDocument(
  File file, {
  int maximumBytes = builtInEditorMaximumBytes,
  Future<String> Function(File file)? sha256Of,
}) async => (await loadBuiltInTextDocumentDetails(
  file,
  maximumBytes: maximumBytes,
  sha256Of: sha256Of,
)).text;

Future<BuiltInTextDocument> loadBuiltInTextDocumentDetails(
  File file, {
  int maximumBytes = builtInEditorMaximumBytes,
  Future<String> Function(File file)? sha256Of,
}) => shared.loadTextDocument(
  file,
  maximumBytes: maximumBytes,
  sha256Of: sha256Of,
);

/// Saves [text] to [file] through the shared guarded replacement, keeping
/// the `.poltergeist` prefix that the checkout recovery sweep recognizes.
/// Existing callers may omit [expectedSha256]; the digest found on disk just
/// before the save then guards it, so a write racing the save still fails
/// rather than being overwritten. Editor views always supply the digest
/// captured when their document was opened.
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
  expectedSha256: expectedSha256 ?? await shared.textDocumentSha256(file),
  temporaryPrefix: '.poltergeist',
  observeTemporary: observeTemporary,
);

/// The §3.2 stream cap for unknown-size checkout downloads (the ported
/// `_MaximumByteSink`): counts forwarded bytes and throws the moment the
/// running total passes [maximumBytes], so a remote file whose listing
/// entry carried no size aborts at the limit instead of downloading in
/// full to a certain refusal.
final class MaximumByteSink implements StreamSink<List<int>> {
  MaximumByteSink(this._inner, {required this.maximumBytes});

  final StreamSink<List<int>> _inner;
  final int maximumBytes;
  int _written = 0;

  void _count(List<int> event) {
    _written += event.length;
    if (_written > maximumBytes) {
      throw CheckoutLimitException(
        'The file is larger than the $maximumBytes-byte '
        'editor limit.',
      );
    }
  }

  @override
  void add(List<int> event) {
    _count(event);
    _inner.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(
    stream.map((event) {
      _count(event);
      return event;
    }),
  );

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}
