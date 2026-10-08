/// What the credential-required tab supplies for a server whose credential
/// this device does not have (CRED-05's inline prompt).
sealed class MissingCredential {
  const MissingCredential();
}

/// The server's password.
final class MissingPassword extends MissingCredential {
  const MissingPassword(this.password);

  final String password;
}

/// The server's private key, as PEM text, and its passphrase if it has one.
final class MissingPrivateKey extends MissingCredential {
  const MissingPrivateKey(this.pem, {this.passphrase});

  final String pem;
  final String? passphrase;
}

/// No stored credential: authenticate through the SSH agent instead.
final class UseSshAgent extends MissingCredential {
  const UseSshAgent();
}
