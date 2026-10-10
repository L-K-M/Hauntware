import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import 'dependency_graph.dart';
import 'source_walker.dart';

const _coreDirectory = 'packages/poltergeist_core';
const _connectionDirectory = '$_coreDirectory/lib/src/connection';

enum _Area { packages, app }

/// The M0 SSH fitness harness is the sanctioned dartssh2 consumer outside
/// poltergeist_core (07 §3.4 relocated it from tool/bench into packages/).
/// It keeps a standalone resolution — dartssh2 4.1.0 and the Séance package
/// via a seance/ sibling path, outside the workspace lock — so it resolves
/// through its own package config, verified like any other scanned package.
const _benchPackage = 'packages/poltergeist_bench';

/// Checks product code only; the relocated M0 harness is a sanctioned SSH
/// consumer with its own resolution.
Future<List<String>> checkImports(String rootPath) async {
  final root = p.normalize(p.absolute(rootPath));
  final graph = await DependencyGraph.load(
    File(p.join(root, '.dart_tool/package_config.json')),
  );
  final benchGraph = await _loadStandaloneGraph(p.join(root, _benchPackage));
  final violations = <String>[];
  var purePackageCount = 0;

  for (final area in _Area.values) {
    final directory = Directory(p.join(root, area.name));

    // Directory.list follows a linked root even when child links are disabled.
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      throw FileSystemException('Linked scan root', directory.path);
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException('Missing scan root', directory.path);
    }

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is Link) {
        throw FileSystemException('Linked package', entity.path);
      }
      if (entity is! Directory) continue;

      final relative = relativeSourcePath(entity.path, root);
      violations.addAll(
        await _checkPackage(
          entity,
          relative,
          _graphFor(relative, graph, benchGraph),
          area,
        ),
      );
      if (area == _Area.packages) purePackageCount++;
    }

    await for (final file in dartSources(directory, root)) {
      final relative = relativeSourcePath(file.path, root);
      violations.addAll(
        await _checkSource(
          file,
          relative,
          _graphFor(relative, graph, benchGraph),
          area,
        ),
      );
    }
  }

  if (purePackageCount == 0) {
    throw const FormatException('No pure-Dart packages found');
  }
  return violations;
}

/// Resolves [relative] against the workspace graph, except the harness's
/// standalone package which resolves through its own package config.
DependencyGraph _graphFor(
  String relative,
  DependencyGraph workspace,
  DependencyGraph? standalone,
) {
  if (relative != _benchPackage && !p.posix.isWithin(_benchPackage, relative)) {
    return workspace;
  }
  if (standalone == null) {
    throw FormatException(
      'Missing $_benchPackage resolution; run dart pub get there',
    );
  }
  return standalone;
}

Future<DependencyGraph?> _loadStandaloneGraph(String packagePath) async {
  final directory = Directory(packagePath);
  if (!directory.existsSync()) return null;

  final config = File(p.join(packagePath, '.dart_tool/package_config.json'));
  if (!config.existsSync()) {
    throw FormatException(
      'Missing $_benchPackage resolution; run dart pub get there',
    );
  }
  return DependencyGraph.load(config);
}

Future<List<String>> _checkPackage(
  Directory directory,
  String relative,
  DependencyGraph graph,
  _Area area,
) async {
  final pubspec = await readPubspec(
    File(p.join(directory.path, 'pubspec.yaml')),
  );
  if (area == _Area.packages) {
    final name = pubspec['name'];
    if (name is! String) {
      throw FormatException('Missing package name: ${directory.path}');
    }
    graph.verifyRoot(name, directory);
  }

  // Overrides and unused declarations can add forbidden edges before an import
  // exists. App declarations need no Flutter resolution in the Dart CI job.
  final manifests = [pubspec];
  final overrides = File(p.join(directory.path, 'pubspec_overrides.yaml'));
  if (await overrides.exists()) manifests.add(await readPubspec(overrides));
  final violations = <String>[];

  for (final manifest in manifests) {
    final dependencies = dependencyNames(manifest, dependencySections).toSet();
    // The harness measures dartssh2 against OpenSSH, so its dependency is
    // sanctioned; every other package outside core's connection layer is not.
    if (relative != _coreDirectory &&
        relative != _benchPackage &&
        dependencies.contains('dartssh2')) {
      violations.add('$relative: dartssh2 dependency outside poltergeist_core');
    }
    if (area != _Area.packages) continue;

    if (requiresFlutter(manifest) ||
        dependencySections.any((section) => hasFlutterSdk(manifest, section))) {
      violations.add(
        '$relative: Flutter/plugin declaration in a pure-Dart package',
      );
      continue;
    }
    for (final dependency in dependencies) {
      final forbidden = await graph.flutterDependency(dependency);
      if (forbidden != null) {
        violations.add('$relative: Flutter/plugin dependency $forbidden');
      }
    }
  }
  return violations;
}

Future<List<String>> _checkSource(
  File file,
  String relative,
  DependencyGraph graph,
  _Area area,
) async {
  final unit = parseString(
    content: await file.readAsString(),
    path: file.path,
  ).unit;
  final violations = <String>[];

  // Parse every branch, including inactive conditional exports. Literal decoding
  // catches escapes while comments and ordinary strings remain harmless.
  for (final directive in unit.directives.whereType<NamespaceDirective>()) {
    final literals = [
      directive.uri,
      ...directive.configurations.map((config) => config.uri),
    ];
    for (final literal in literals) {
      final text = literal.stringValue;
      if (text == null) {
        violations.add('$relative: non-constant import/export URI');
        continue;
      }
      final uri = Uri.parse(text);
      if (uri.scheme == 'package' && uri.pathSegments.isEmpty) {
        violations.add('$relative: invalid package URI $uri');
        continue;
      }
      final package = uri.scheme == 'package' ? uri.pathSegments.first : null;
      if (package == 'dartssh2' &&
          !p.posix.isWithin(_connectionDirectory, relative) &&
          !p.posix.isWithin(_benchPackage, relative)) {
        violations.add(
          '$relative: dartssh2 import/export outside $_connectionDirectory',
        );
      }
      if (area != _Area.packages) continue;

      if (uri.scheme == 'dart' && (uri.path == 'ui' || uri.path == 'ui_web')) {
        violations.add('$relative: Flutter SDK import/export $uri');
        continue;
      }
      if (package == null) continue;
      final forbidden = await graph.flutterDependency(package);
      if (forbidden != null) {
        violations.add('$relative: Flutter/plugin import/export $forbidden');
      }
    }
  }
  return violations;
}
