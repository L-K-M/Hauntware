/// The third-party notices Flutter's NOTICES cannot hold, for the licenses
/// page every Ghost app opens.
///
/// Flutter collects the engine's, the Dart runtime's and every pub
/// package's license texts. On Android the APK also carries the Maven
/// libraries the plugins pull in (AndroidX, Kotlin, Tink and the like),
/// which the AboutLibraries Gradle plugin lists, with their license texts,
/// in res/raw/aboutlibraries.json. [registerPlatformLicenses] adds those
/// to [LicenseRegistry], so [showLicensePage] shows them beside the rest.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('ghost_licenses');

/// Registers the platform's extra notices with [LicenseRegistry]: on
/// Android, the Maven libraries of the APK; elsewhere nothing. Cheap: the
/// definitions are read only when a licenses page asks for them.
void registerPlatformLicenses() {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  LicenseRegistry.addLicense(_androidLibraryLicenses);
}

/// The licenses page folds every source into one stream, so an error from
/// this source would replace Flutter's, Dart's and the pub packages'
/// notices with the error text. A failure is reported and shown as one
/// entry instead.
Stream<LicenseEntry> _androidLibraryLicenses() async* {
  final List<LicenseEntry> entries;
  try {
    final definitions = await _channel.invokeMethod<String>(
      'libraryDefinitions',
    );
    if (definitions == null) {
      throw StateError('The Android host returned no library definitions.');
    }
    entries = libraryLicenses(definitions);
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'ghost_licenses',
        context: ErrorDescription('while reading the Android library notices'),
      ),
    );
    yield const LicenseEntryWithLineBreaks([
      'Android libraries',
    ], 'The notices of the Android libraries could not be read.');
    return;
  }
  yield* Stream.fromIterable(entries);
}

/// The license entries of AboutLibraries library definitions [json]: one
/// per license, naming every library (with its version) that uses it, so
/// the licenses page lists each library and shows the full text.
///
/// A library entry without an id or a license list is skipped; the release
/// checks keep such an entry from shipping. Throws [FormatException] when
/// [json] is not a definitions object at all.
@visibleForTesting
List<LicenseEntry> libraryLicenses(String json) {
  final definitions = jsonDecode(json);
  if (definitions is! Map<String, Object?> ||
      definitions['libraries'] is! List<Object?>) {
    throw const FormatException('Not AboutLibraries library definitions.');
  }
  final licenses = switch (definitions['licenses']) {
    final Map<String, Object?> licenses => licenses,
    _ => const <String, Object?>{},
  };
  final users = <String, List<String>>{};
  for (final library in definitions['libraries']! as List<Object?>) {
    if (library case {
      'uniqueId': final String id,
      'licenses': final List<Object?> keys,
    }) {
      if (keys.any((key) => key is! String)) continue;
      final version = library['artifactVersion'];
      final name = [id, if (version is String) version].join(' ');
      for (final key in keys.cast<String>()) {
        users.putIfAbsent(key, () => []).add(name);
      }
    }
  }

  return [
    for (final MapEntry(key: key, value: names) in users.entries)
      LicenseEntryWithLineBreaks(names, _text(key, licenses[key])),
  ];
}

/// A license's text, or its name and URL when the definitions carry no
/// text (the release checks keep that from shipping).
String _text(String key, Object? license) {
  final fields = license is Map<String, Object?> ? license : const {};
  final content = fields['content'];
  if (content is String && content.trim().isNotEmpty) return content;

  final name = fields['name'];
  final url = fields['url'];
  return [name is String ? name : key, if (url is String) url].join('\n\n');
}
