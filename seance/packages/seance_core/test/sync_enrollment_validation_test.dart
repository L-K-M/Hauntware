import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  const validUrl = 'https://sync.example.com';
  const passphrase = 'correct horse battery staple';

  SyncEnrollmentIssue? validate({
    SyncEnrollmentMode mode = SyncEnrollmentMode.register,
    String baseUrl = validUrl,
    String username = 'alice',
    String password = 'server account password',
    String encryptionPassphrase = passphrase,
    String confirmation = passphrase,
  }) => validateSyncEnrollment(
    mode: mode,
    baseUrl: baseUrl,
    username: username,
    password: password,
    encryptionPassphrase: encryptionPassphrase,
    confirmationPassphrase: confirmation,
  );

  test('accepts a complete registration and login', () {
    expect(validate(), isNull);
    expect(validate(mode: SyncEnrollmentMode.login, confirmation: ''), isNull);
    // Plain HTTP stays valid for local and self-hosted servers.
    expect(validate(baseUrl: 'http://localhost:8080'), isNull);
  });

  test('refuses a server URL that is not HTTP(S) with a host', () {
    for (final url in ['   ', 'ssh://sync.example.com', 'https:///no-host']) {
      expect(
        validate(baseUrl: url),
        SyncEnrollmentIssue.invalidServerUrl,
        reason: url,
      );
    }
  });

  test('refuses credentials embedded in the URL', () {
    expect(
      validate(baseUrl: 'https://alice:secret@sync.example.com'),
      SyncEnrollmentIssue.credentialsInUrl,
    );
  });

  test('requires every field, blank as missing', () {
    expect(validate(username: '  '), SyncEnrollmentIssue.missingUsername);
    expect(validate(password: '\t'), SyncEnrollmentIssue.missingPassword);
    expect(
      validate(encryptionPassphrase: ' '),
      SyncEnrollmentIssue.missingEncryptionPassphrase,
    );
  });

  test('registration alone needs a matching confirmation', () {
    expect(
      validate(confirmation: ' '),
      SyncEnrollmentIssue.missingConfirmation,
    );
    expect(
      validate(confirmation: 'something else'),
      SyncEnrollmentIssue.confirmationMismatch,
    );
    expect(
      validate(mode: SyncEnrollmentMode.login, confirmation: 'ignored'),
      isNull,
    );
  });
}
