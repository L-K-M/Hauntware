import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import 'dependency_graph.dart';
import 'guards_config.dart';
import 'source_walker.dart';

/// Checks one product's scan areas against its `tool/guards.yaml` entry.
/// Reported paths are relative to the repository root, so they gain the
/// product directory as a prefix.
Future<List<String>> checkImports(
  String repositoryRoot,
  ProductGuard product,
) async {
  final root = p.normalize(p.absolute(repositoryRoot));
  final productRoot = p.join(root, product.name);
  final workspaceConfig = File(
    p.join(productRoot, '.dart_tool/package_config.json'),
  );
  if (!workspaceConfig.existsSync()) {
    throw FormatException(
      'Missing ${product.name}/.dart_tool/package_config.json; '
      'run dart pub get',
    );
  }
  final graph = await DependencyGraph.load(workspaceConfig);
  final standalone = {
    for (final directory in product.standaloneResolutions)
      directory: await _loadStandaloneGraph(product, productRoot, directory),
  };
  final violations = <String>[];
  var purePackageCount = 0;

  for (final area in product.scan) {
    final directory = Directory(p.join(productRoot, area));

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

      final relative = p.posix.join(area, p.basename(entity.path));
      violations.addAll(
        await _checkPackage(
          entity,
          relative,
          product,
          _graphFor(relative, product, graph, standalone),
        ),
      );
      if (product.isPurePackage(relative)) purePackageCount++;
    }

    await for (final file in dartSources(
      directory,
      productRoot,
      product.scanAreas,
    )) {
      final relative = relativeSourcePath(file.path, productRoot);
      violations.addAll(
        await _checkSource(
          file,
          relative,
          product,
          _graphFor(relative, product, graph, standalone),
        ),
      );
    }
  }

  if (purePackageCount == 0) {
    throw const FormatException('No pure-Dart packages found');
  }
  return violations;
}

/// Reported paths are relative to the repository root.
String _reported(ProductGuard product, String relative) =>
    '${product.name}/$relative';

/// Resolves [relative] against the workspace graph, except the packages
/// whose standalone resolutions the product declares.
DependencyGraph _graphFor(
  String relative,
  ProductGuard product,
  DependencyGraph workspace,
  Map<String, DependencyGraph?> standalone,
) {
  for (final entry in product.standaloneResolutions) {
    if (relative != entry && !p.posix.isWithin(entry, relative)) continue;

    final graph = standalone[entry];
    if (graph == null) {
      throw FormatException(
        'Missing ${_reported(product, entry)} resolution; '
        'run dart pub get there',
      );
    }
    return graph;
  }
  return workspace;
}

Future<DependencyGraph?> _loadStandaloneGraph(
  ProductGuard product,
  String productRoot,
  String relative,
) async {
  final directory = Directory(p.join(productRoot, relative));
  if (!directory.existsSync()) return null;

  final config = File(p.join(directory.path, '.dart_tool/package_config.json'));
  if (!config.existsSync()) {
    throw FormatException(
      'Missing ${_reported(product, relative)} resolution; '
      'run dart pub get there',
    );
  }
  return DependencyGraph.load(config);
}

Future<List<String>> _checkPackage(
  Directory directory,
  String relative,
  ProductGuard product,
  DependencyGraph graph,
) async {
  final pubspec = await readPubspec(
    File(p.join(directory.path, 'pubspec.yaml')),
  );
  final pure = product.isPurePackage(relative);
  if (pure) {
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
    if (!product.dartssh2Dependents.contains(relative) &&
        dependencies.contains('dartssh2')) {
      violations.add(
        '${_reported(product, relative)}: dartssh2 dependency outside '
        '${_dartssh2DependentName(product)}',
      );
    }
    if (!pure) continue;

    if (requiresFlutter(manifest) ||
        dependencySections.any((section) => hasFlutterSdk(manifest, section))) {
      violations.add(
        '${_reported(product, relative)}: Flutter/plugin declaration in a '
        'pure-Dart package',
      );
      continue;
    }
    for (final dependency in dependencies) {
      final forbidden = await graph.flutterDependency(dependency);
      if (forbidden != null) {
        violations.add(
          '${_reported(product, relative)}: Flutter/plugin dependency '
          '$forbidden',
        );
      }
    }
  }
  return violations;
}

String _dartssh2DependentName(ProductGuard product) =>
    product.dartssh2Dependents.isEmpty
    ? 'the configured dartssh2 dependents'
    : p.posix.basename(product.dartssh2Dependents.first);

Future<List<String>> _checkSource(
  File file,
  String relative,
  ProductGuard product,
  DependencyGraph graph,
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
        violations.add(
          '${_reported(product, relative)}: non-constant import/export URI',
        );
        continue;
      }
      final uri = Uri.parse(text);
      if (uri.scheme == 'package' && uri.pathSegments.isEmpty) {
        violations.add(
          '${_reported(product, relative)}: invalid package URI $uri',
        );
        continue;
      }
      final package = uri.scheme == 'package' ? uri.pathSegments.first : null;
      if (package == 'dartssh2' && !product.allowsDartssh2Import(relative)) {
        violations.add(
          '${_reported(product, relative)}: dartssh2 import/export outside '
          '${_dartssh2ImportArea(product)}',
        );
      }
      if (!_insidePurePackage(product, relative)) continue;

      if (uri.scheme == 'dart' && (uri.path == 'ui' || uri.path == 'ui_web')) {
        violations.add(
          '${_reported(product, relative)}: Flutter SDK import/export $uri',
        );
        continue;
      }
      if (package == null) continue;
      final forbidden = await graph.flutterDependency(package);
      if (forbidden != null) {
        violations.add(
          '${_reported(product, relative)}: Flutter/plugin import/export '
          '$forbidden',
        );
      }
    }
  }
  return violations;
}

String _dartssh2ImportArea(ProductGuard product) =>
    product.dartssh2Imports.isEmpty
    ? 'the configured dartssh2 import areas'
    : _reported(product, product.dartssh2Imports.first);

/// Whether [relative] (product-relative) sits inside a pure package: the
/// second path segment under a scan area is the package directory.
bool _insidePurePackage(ProductGuard product, String relative) {
  final segments = p.posix.split(relative);
  if (segments.length < 2 || !product.scanAreas.contains(segments.first)) {
    return false;
  }
  return product.isPurePackage(p.posix.join(segments[0], segments[1]));
}
