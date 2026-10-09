import 'package:seance_core/seance_core.dart';

/// Séance's sentence for each [SyncEnrollmentIssue] seance_core's enrollment
/// rules report, shown in the Sync settings status line.
String syncEnrollmentIssueMessage(SyncEnrollmentIssue issue) =>
    switch (issue) {
      SyncEnrollmentIssue.invalidServerUrl =>
        'Enter a valid HTTP or HTTPS server URL.',
      SyncEnrollmentIssue.credentialsInUrl =>
        'Server URL must not include embedded credentials.',
      SyncEnrollmentIssue.missingUsername => 'Enter a username.',
      SyncEnrollmentIssue.missingPassword =>
        'Enter the sync account password.',
      SyncEnrollmentIssue.missingEncryptionPassphrase =>
        'Enter the vault encryption passphrase.',
      SyncEnrollmentIssue.missingConfirmation =>
        'Confirm the vault encryption passphrase before registering.',
      SyncEnrollmentIssue.confirmationMismatch =>
        'Vault encryption passphrases do not match.',
    };
