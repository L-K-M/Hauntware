import 'package:klabautermann_core/klabautermann_core.dart';

/// Each failure kind's English words (03 §5.3, §10.1), written out so a
/// test fails when the copy or the kind it belongs to changes.
const Map<LinkFailureKind, String> failureTexts = {
  LinkFailureKind.unreachable:
      'This server could not be reached. Check its address and your network '
      'connection.',
  LinkFailureKind.timedOut:
      'This server did not answer in time. Check that it is running and '
      'that your network reaches it.',
  LinkFailureKind.authenticationRejected:
      'The server rejected your credentials. Make sure it trusts your key or '
      'password.',
  LinkFailureKind.credentialUnavailable:
      'No credential could be offered to this server. Check that its key '
      'file can be read and holds a supported key, or load a key into '
      'ssh-agent.',
  LinkFailureKind.keyPassphraseRequired:
      'A key for this server needs a passphrase, which Klabautermann cannot '
      'ask for. Load the key into ssh-agent and remove the IdentityFile line '
      'that names it from ~/.ssh/config, then import the config again.',
  // The Flatpak variant.
  LinkFailureKind.keyFileHiddenBySandbox:
      'A key file for this server cannot be read in the Flatpak sandbox. '
      'Load the key into ssh-agent and remove the IdentityFile line that '
      'names it from ~/.ssh/config, then import the config again.',
  LinkFailureKind.hostKeyDeclined:
      "This server's host key has not been trusted, so Klabautermann did not "
      'connect.',
  LinkFailureKind.keyboardInteractiveCancelled:
      "The server's sign-in questions were cancelled, so Klabautermann did "
      'not connect.',
  LinkFailureKind.unsupportedAlgorithm:
      'This server requires an algorithm Klabautermann does not support yet.',
  LinkFailureKind.insecureAlgorithmsOnly:
      'This server offers only algorithms Klabautermann refuses as insecure.',
  LinkFailureKind.keyExchangeTimedOut:
      "Klabautermann could not finish this server's key exchange in time on "
      'this device.',
};
