import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Readers for the native runner sources the Linux-run contract tests
// check, since only each platform's toolchain compiles them.

/// Line endings normalized, so a CRLF checkout reads the same.
String readSource(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// The id of the file reference to [path] in [project], or null.
String? xcodeFileReferenceId(String project, String path) {
  final quoted = path.contains('-') ? '"$path"' : path;
  return RegExp(
    '([0-9A-F]{24}) /\\* ${RegExp.escape(path)} \\*/ = \\{isa = '
    'PBXFileReference;[^}]*path = ${RegExp.escape(quoted)};',
  ).firstMatch(project)?[1];
}

/// The id of the Runner group, which holds the runner's sources.
String xcodeRunnerGroupId(String project) {
  final matches = RegExp(
    r'([0-9A-F]{24}) /\* Runner \*/ = \{\n\t\t\tisa = PBXGroup;'
    r'[^}]*?\n\t\t\tpath = Runner;',
  ).allMatches(project).toList();
  expect(matches, hasLength(1), reason: 'one Runner group');
  return matches.single[1]!;
}

/// The ids in the parenthesized [list] of the object [id].
List<String> xcodeListEntries(String project, String id, String list) {
  final body = RegExp(
    '\\t\\t$id /\\*[^*]*\\*/ = \\{\\n(.*?)\\n\\t\\t\\};',
    dotAll: true,
  ).firstMatch(project)?[1];
  expect(body, isNotNull, reason: 'object $id');
  final entries = RegExp(
    '\\t\\t\\t$list = \\((.*?)\\);',
    dotAll: true,
  ).firstMatch(body!)?[1];
  expect(entries, isNotNull, reason: '$list of $id');
  return RegExp(
    r'\b([0-9A-F]{24})\b',
  ).allMatches(entries!).map((match) => match[1]!).toList();
}

/// The build files of [target]'s Sources phase.
List<String> xcodeTargetSources(String project, String target) {
  final targetId = RegExp(
    '([0-9A-F]{24}) /\\* $target \\*/ = \\{\\n\\t\\t\\tisa = '
    'PBXNativeTarget;',
  ).firstMatch(project)?[1];
  expect(targetId, isNotNull, reason: 'target $target');

  final phases = xcodeListEntries(project, targetId!, 'buildPhases');
  final sources = phases.where(
    (id) => RegExp(
      '\\t\\t$id /\\* Sources \\*/ = \\{\\n\\t\\t\\tisa = '
      'PBXSourcesBuildPhase;',
    ).hasMatch(project),
  );
  expect(sources, hasLength(1), reason: 'Sources phase of $target');
  return xcodeListEntries(project, sources.single, 'files');
}
