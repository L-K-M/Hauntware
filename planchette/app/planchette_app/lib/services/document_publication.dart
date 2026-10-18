import 'package:flutter/foundation.dart';

/// A host-owned destination beyond the document's guarded local working copy.
/// A local save alone must not clear the window's remote-save warning.
abstract class DocumentPublication extends ChangeNotifier {
  String get displayPath;
  String get sourcePath;
  bool get pending;
  void localSaved(String digest);
  Future<bool> publish();
  Future<void> discard();
}
