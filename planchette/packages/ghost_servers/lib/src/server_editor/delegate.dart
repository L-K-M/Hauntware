import 'package:flutter/widgets.dart';

import '../connection_test_report.dart' show GhostTestReport;
import 'draft.dart';

/// What the server editor needs from its host (docs/design/
/// ghost-servers-part2.md, section 5): the seams it uses, named one per use.
abstract class GhostServerEditorDelegate {
  /// The distinct group names to offer as quick picks, in display order.
  List<String> get serverGroups;

  /// Whether a sync account is linked; gates the exclusion confirmation.
  bool get syncConfigured;

  /// The host's own seed colour, the custom colour picker's start when no
  /// named accent is in force.
  Color get themeSeed;

  /// A fresh id. The editor asks twice when it opens: for a new server and
  /// for the vault entry a new credential goes under.
  String newId();

  /// Whether Browse is offered beside the identity file path.
  bool get canPickIdentityFile => true;

  /// Whether Test connection is offered. A host without a connection
  /// test yet answers false, and the button and its disclaimer are not
  /// shown.
  bool get canTestConnection => true;

  /// Picks a "reference, don't store" identity file; null when cancelled.
  Future<String?> pickIdentityFile();

  /// Whether Import from file is offered under the pasted key: a host
  /// whose key files cannot be referenced, such as a phone's, reads one
  /// into the box instead, and the key is stored as a pasted one is.
  bool get canImportKeyFile => false;

  /// The text of a private key file the user picks, for the pasted-key
  /// box; null when cancelled. Throws when the file cannot be read as
  /// text, and the editor says so.
  Future<String?> importKeyFile() async => null;

  /// Plans and writes the credential, then the server. Throws on failure,
  /// and the editor shows `saveFailed` and stays open. Returns whether a
  /// credential was written.
  Future<bool> save(GhostServerSave save);

  /// Authenticates against the form's draft, typed but unsaved credential
  /// included. Expected to turn every failure into a report; the editor
  /// still catches one that escapes, with an empty log.
  Future<GhostTestReport> testConnection(
    GhostServerDraft draft,
    GhostCredentialDraft credential,
  );
}

/// A host's own section of the form, drawn after the login script.
/// Poltergeist's transfer limit is the one user.
abstract class GhostServerEditorSection {
  Widget build(BuildContext context);

  /// Read when Save is pressed, before anything is awaited, so an edit made
  /// while the save runs is not in it: the write to run once the server has
  /// saved, with its id, or null when nothing changed.
  Future<void> Function(String serverId)? capture();

  /// The toast for a failed write; the editor stays open so Save retries.
  String failureMessage(Object error);
}
