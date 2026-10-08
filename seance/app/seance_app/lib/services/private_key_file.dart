import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'picked_file_bytes.dart';

/// The largest private key file read into a credential: far above any real
/// key (an RSA-16384 PEM is about 12 KiB), and small enough that a wrong pick
/// costs nothing.
const int maxPrivateKeyFileBytes = 64 * 1024;

/// A private key file the user picks, as text, or null when they cancelled.
/// Throws [FormatException] for a file that is too large or not text.
Future<String?> pickPrivateKeyText() async {
  // A wrong pick must not allocate the whole file before applying the limit.
  final result = await FilePicker.pickFiles(withReadStream: true);
  // Some platforms answer a cancel with an empty result rather than null.
  if (result == null || result.files.isEmpty) return null;
  final Uint8List bytes;
  try {
    bytes = await readPickedFileBytes(
      result.files.single,
      maxBytes: maxPrivateKeyFileBytes,
    );
  } on PickedFileTooLargeException {
    throw const FormatException('That file is too large to be a private key.');
  } on FileSystemException {
    throw const FormatException('That file could not be read.');
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const FormatException('That file is not a text private key.');
  }
}
