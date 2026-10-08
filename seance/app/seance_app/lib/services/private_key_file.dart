import 'dart:convert';

import 'package:file_picker/file_picker.dart';

/// The largest private key file read into a credential: far above any real
/// key (an RSA-16384 PEM is about 12 KiB), and small enough that a wrong pick
/// costs nothing.
const int maxPrivateKeyFileBytes = 64 * 1024;

/// A private key file the user picks, as text, or null when they cancelled.
/// Throws [FormatException] for a file that is too large or not text.
Future<String?> pickPrivateKeyText() async {
  // `withData`: on Android a document provider may have no path at all.
  final result = await FilePicker.pickFiles(withData: true);
  final file = result?.files.single;
  if (file == null) return null;
  if (file.size > maxPrivateKeyFileBytes) {
    throw const FormatException('That file is too large to be a private key.');
  }
  final bytes = file.bytes;
  if (bytes == null) {
    throw const FormatException('That file could not be read.');
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const FormatException('That file is not a text private key.');
  }
}
