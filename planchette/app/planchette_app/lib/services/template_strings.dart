import 'dart:ui' show Locale;

import '../l10n/app_localizations.dart';

/// The catalog's template locale, English, for code no window localizes:
/// the tests, a service built before any window exists, and a native
/// picker opened before its navigator has a context.
AppLocalizations templateStrings() =>
    lookupAppLocalizations(const Locale('en'));
