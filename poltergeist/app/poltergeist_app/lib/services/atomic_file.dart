// Ported from Séance app/seance_app/lib/services/atomic_file.dart @ e11206a; see docs/PORTS.md.
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart'
    show AtomicFilePrivacy, AtomicFileWriter;

export 'package:poltergeist_core/poltergeist_core.dart'
    show AtomicFilePrivacy;

/// Replaces [target] without exposing partially written contents.
Future<void> writeStringAtomically(
  File target,
  String contents, {
  AtomicFilePrivacy privacy = AtomicFilePrivacy.processDefault,
}) => const AtomicFileWriter().write(target, contents, privacy: privacy);

/// [writeStringAtomically] with owner-only privacy: the rewrite the
/// identity audit log rotates through.
Future<void> writeOwnerOnlyAtomically(File file, String contents) =>
    writeStringAtomically(file, contents, privacy: AtomicFilePrivacy.ownerOnly);
