import '../sensitive_transport_policy.dart';

/// Which enrollment shape the validator checks: register carries the
/// passphrase confirmation requirement, login does not.
enum SyncEnrollmentMode { register, login }

/// The failure [validateSyncEnrollment] reports. Each host words it
/// itself: Séance in its settings sentences, Poltergeist through its
/// localizations.
enum SyncEnrollmentIssue {
  invalidServerUrl,
  credentialsInUrl,
  missingUsername,
  missingPassword,
  missingEncryptionPassphrase,
  missingConfirmation,
  confirmationMismatch,
}

/// Returns the issue blocking enrollment from contacting the server, or
/// null when the request is ready to run.
SyncEnrollmentIssue? validateSyncEnrollment({
  required SyncEnrollmentMode mode,
  required String baseUrl,
  required String username,
  required String password,
  required String encryptionPassphrase,
  String confirmationPassphrase = '',
}) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null || !isAllowedSensitiveTransport(uri)) {
    return SyncEnrollmentIssue.invalidServerUrl;
  }
  if (uri.userInfo.isNotEmpty) {
    return SyncEnrollmentIssue.credentialsInUrl;
  }
  if (username.trim().isEmpty) return SyncEnrollmentIssue.missingUsername;
  if (password.trim().isEmpty) return SyncEnrollmentIssue.missingPassword;
  if (encryptionPassphrase.trim().isEmpty) {
    return SyncEnrollmentIssue.missingEncryptionPassphrase;
  }
  if (mode == SyncEnrollmentMode.register) {
    if (confirmationPassphrase.trim().isEmpty) {
      return SyncEnrollmentIssue.missingConfirmation;
    }
    if (confirmationPassphrase != encryptionPassphrase) {
      return SyncEnrollmentIssue.confirmationMismatch;
    }
  }
  return null;
}
