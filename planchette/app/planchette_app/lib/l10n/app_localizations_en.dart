// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get actionBack => 'Back';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionClose => 'Close';

  @override
  String get actionOpen => 'Open';

  @override
  String get actionSignIn => 'Sign In';

  @override
  String get serversTitle => 'Workspace servers';

  @override
  String get serversRefresh => 'Refresh catalog';

  @override
  String get serversSignInPrompt => 'Sign in to your existing suite catalog.';

  @override
  String get serversUrl => 'Server URL';

  @override
  String get serversUsername => 'Username';

  @override
  String get serversPassword => 'Account password';

  @override
  String get serversPassphrase => 'Encryption passphrase';

  @override
  String get serversSyncCredentials => 'Sync saved passwords and keys';

  @override
  String get serversSyncCredentialsDetail =>
      'Optional. Credentials stay encrypted on this device.';

  @override
  String get serversDownloadOnly =>
      'Planchette only downloads catalog changes.';

  @override
  String serversAccount(String username, String baseUrl) {
    return '$username · $baseUrl';
  }

  @override
  String get serversSearch => 'Search servers';

  @override
  String get serversEmptyCatalog =>
      'No servers in the cached catalog. Refresh to download changes.';

  @override
  String get serversNoMatch => 'No matching servers.';

  @override
  String hostKeyConflict(String locator) {
    return 'Another device synced a different host key for $locator. Planchette kept this device\'s key and is not using the other one. If the server\'s key really changed, trust the new one; otherwise keep yours.';
  }

  @override
  String get hostKeyLocal => 'This device trusts';

  @override
  String get hostKeyPulled => 'The other device synced';

  @override
  String get hostKeyKeepLocal => 'Keep this device\'s key';

  @override
  String get hostKeyTrustNew => 'Trust the new key';

  @override
  String remoteFolderTitle(String server) {
    return 'Open Folder on $server';
  }

  @override
  String get remoteFolderLabel => 'Remote folder';

  @override
  String get remoteFolderHelper =>
      'Absolute path or relative to your login home.';

  @override
  String get remoteFolderInvalid => 'Enter a folder using /path, ~ or ~/path.';

  @override
  String get credentialExplanation =>
      'Used for this workspace session and never saved.';

  @override
  String get credentialRetry =>
      'That passphrase did not open the key. Try again. It is used for this workspace session and never saved.';

  @override
  String get credentialConnect => 'Connect';
}
