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

Stream<LicenseEntry> _androidLibraryLicenses() async* {
  final definitions = await _channel.invokeMethod<String>('libraryDefinitions');
  if (definitions == null) {
    throw StateError('The Android host returned no library definitions.');
  }
  yield* Stream.fromIterable(libraryLicenses(definitions));
}

/// The license entries of AboutLibraries library definitions [json]: one
/// per license, naming every library (with its version) that uses it, so
/// the licenses page lists each library and shows the full text.
@visibleForTesting
List<LicenseEntry> libraryLicenses(String json) {
  final definitions = jsonDecode(json) as Map<String, Object?>;
  final licenses = definitions['licenses']! as Map<String, Object?>;
  final users = <String, List<String>>{};
  for (final library in definitions['libraries']! as List<Object?>) {
    final fields = library! as Map<String, Object?>;
    final version = fields['artifactVersion'] as String?;
    final name = [fields['uniqueId']! as String, ?version].join(' ');
    for (final key in fields['licenses']! as List<Object?>) {
      users.putIfAbsent(key! as String, () => []).add(name);
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
  final fields = license as Map<String, Object?>? ?? const {};
  final content = fields['content'] as String?;
  if (content != null && content.trim().isNotEmpty) return content;

  return [fields['name'] ?? key, ?fields['url']].join('\n\n');
}
