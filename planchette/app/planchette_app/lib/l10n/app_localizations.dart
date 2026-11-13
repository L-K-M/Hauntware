import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Returns from the sign-in form to the server list.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get actionBack;

  /// Closes a dialog without acting.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// Closes the workspace servers dialog.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// Opens the chosen remote folder.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get actionOpen;

  /// Shows or submits the catalog sign-in form.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get actionSignIn;

  /// Title of the dialog that lists the synced server catalog.
  ///
  /// In en, this message translates to:
  /// **'Workspace servers'**
  String get serversTitle;

  /// Tooltip of the button that downloads catalog changes.
  ///
  /// In en, this message translates to:
  /// **'Refresh catalog'**
  String get serversRefresh;

  /// Heading of the catalog sign-in form.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your existing suite catalog.'**
  String get serversSignInPrompt;

  /// Label of the sync server address field.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get serversUrl;

  /// Label of the catalog account name field.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get serversUsername;

  /// Label of the catalog account password field.
  ///
  /// In en, this message translates to:
  /// **'Account password'**
  String get serversPassword;

  /// Label of the catalog encryption passphrase field.
  ///
  /// In en, this message translates to:
  /// **'Encryption passphrase'**
  String get serversPassphrase;

  /// Switch that also downloads stored server credentials.
  ///
  /// In en, this message translates to:
  /// **'Sync saved passwords and keys'**
  String get serversSyncCredentials;

  /// Explains the credential sync switch.
  ///
  /// In en, this message translates to:
  /// **'Optional. Credentials stay encrypted on this device.'**
  String get serversSyncCredentialsDetail;

  /// Says the editor never uploads catalog changes.
  ///
  /// In en, this message translates to:
  /// **'Planchette only downloads catalog changes.'**
  String get serversDownloadOnly;

  /// The signed-in catalog account above the server list.
  ///
  /// In en, this message translates to:
  /// **'{username} · {baseUrl}'**
  String serversAccount(String username, String baseUrl);

  /// Label of the server list filter field.
  ///
  /// In en, this message translates to:
  /// **'Search servers'**
  String get serversSearch;

  /// Shown when the downloaded catalog has no servers.
  ///
  /// In en, this message translates to:
  /// **'No servers in the cached catalog. Refresh to download changes.'**
  String get serversEmptyCatalog;

  /// Shown when the filter matches no server.
  ///
  /// In en, this message translates to:
  /// **'No matching servers.'**
  String get serversNoMatch;

  /// Explains a synced host key that differs from this device's pin.
  ///
  /// In en, this message translates to:
  /// **'Another device synced a different host key for {locator}. Planchette kept this device\'s key and is not using the other one. If the server\'s key really changed, trust the new one; otherwise keep yours.'**
  String hostKeyConflict(String locator);

  /// Heads this device's pinned host key fingerprint.
  ///
  /// In en, this message translates to:
  /// **'This device trusts'**
  String get hostKeyLocal;

  /// Heads the synced host key fingerprint.
  ///
  /// In en, this message translates to:
  /// **'The other device synced'**
  String get hostKeyPulled;

  /// Keeps the pinned host key and drops the synced one.
  ///
  /// In en, this message translates to:
  /// **'Keep this device\'s key'**
  String get hostKeyKeepLocal;

  /// Replaces the pinned host key with the synced one.
  ///
  /// In en, this message translates to:
  /// **'Trust the new key'**
  String get hostKeyTrustNew;

  /// Title of the dialog that opens a server folder as a workspace.
  ///
  /// In en, this message translates to:
  /// **'Open Folder on {server}'**
  String remoteFolderTitle(String server);

  /// Label of the server folder path field.
  ///
  /// In en, this message translates to:
  /// **'Remote folder'**
  String get remoteFolderLabel;

  /// Explains the accepted server folder paths.
  ///
  /// In en, this message translates to:
  /// **'Absolute path or relative to your login home.'**
  String get remoteFolderHelper;

  /// Shown when the server folder path has no accepted form.
  ///
  /// In en, this message translates to:
  /// **'Enter a folder using /path, ~ or ~/path.'**
  String get remoteFolderInvalid;

  /// Explains how a server credential typed for a workspace is kept.
  ///
  /// In en, this message translates to:
  /// **'Used for this workspace session and never saved.'**
  String get credentialExplanation;

  /// Shown when a key passphrase was wrong.
  ///
  /// In en, this message translates to:
  /// **'That passphrase did not open the key. Try again. It is used for this workspace session and never saved.'**
  String get credentialRetry;

  /// Submits a server credential.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get credentialConnect;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
