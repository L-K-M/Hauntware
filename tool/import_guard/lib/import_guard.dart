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
  final packages = <String, _ScannedPackage>{};
  var purePackageCount = 0;

  for (final area in product.scan) {
    final directory = _scanRoot(productRoot, area);
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is Link) {
        throw FileSystemException('Linked package', entity.path);
      }
      if (entity is! Directory) continue;

      final relative = p.posix.join(area, p.basename(entity.path));
      final package = await _loadPackage(
        entity,
        relative,
        product,
        _graphFor(relative, product, graph, standalone),
      );
      packages[relative] = package;
      violations.addAll(await _checkPackage(package, product));
      if (package.pure) purePackageCount++;
    }
  }

  for (final area in product.scan) {
    final directory = _scanRoot(productRoot, area);
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
          _containingPackage(relative, packages),
        ),
      );
    }
  }

  if (purePackageCount == 0) {
    throw const FormatException('No pure-Dart packages found');
  }
  return violations;
}

/// Resolves a configured scan root, failing closed on a linked or absent
/// directory.
Directory _scanRoot(String productRoot, String area) {
  final directory = Directory(p.join(productRoot, area));
  final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FileSystemException('Linked scan root', directory.path);
  }
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException('Missing scan root', directory.path);
  }
  return directory;
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

/// The scanned package under [directory], with its parsed manifests and
/// the forbidden patterns and allowlist that apply to its name.
Future<_ScannedPackage> _loadPackage(
  Directory directory,
  String relative,
  ProductGuard product,
  DependencyGraph graph,
) async {
  final pubspec = await readPubspec(
    File(p.join(directory.path, 'pubspec.yaml')),
  );
  final overrides = File(p.join(directory.path, 'pubspec_overrides.yaml'));
  final name = pubspec['name'];
  return _ScannedPackage(
    directory: directory,
    relative: relative,
    name: name is String ? name : null,
    pubspec: pubspec,
    overrides: await overrides.exists() ? await readPubspec(overrides) : null,
    pure: product.isPurePackage(relative),
    graph: graph,
    forbidden: name is String
        ? product.forbiddenDependenciesFor(name)
        : const {},
    allowed: name is String ? product.allowedDependenciesFor(name) : null,
  );
}

/// The scanned package that owns [relative] (product-relative), if any:
/// the first two path segments under a scan area name the package.
_ScannedPackage? _containingPackage(
  String relative,
  Map<String, _ScannedPackage> packages,
) {
  final segments = p.posix.split(relative);
  if (segments.length < 2) return null;
  return packages[p.posix.join(segments[0], segments[1])];
}

Future<List<String>> _checkPackage(
  _ScannedPackage package,
  ProductGuard product,
) async {
  final relative = package.relative;
  if (package.pure) {
    final name = package.name;
    if (name == null) {
      throw FormatException('Missing package name: ${package.directory.path}');
    }
    package.graph.verifyRoot(name, package.directory);
  }

  // Overrides and unused declarations can add forbidden edges before an
  // import exists. App declarations need no Flutter resolution in the Dart
  // CI job.
  final manifests = [
    package.pubspec,
    if (package.overrides != null) package.overrides!,
  ];
  final violations = <String>[];

  for (final manifest in manifests) {
    _checkDartssh2Dependencies(manifest, package, product, violations);
    final dependencies = dependencyNames(manifest, dependencySections).toSet();
    for (final dependency in dependencies) {
      if (_matchesAny(package.forbidden, dependency)) {
        violations.add(
          '${_reported(product, relative)}: forbidden dependency $dependency',
        );
      }
    }
    final allowed = package.allowed;
    if (allowed == null) continue;
    for (final dependency in dependencyNames(
      manifest,
      _runtimeDependencySections,
    ).toSet()) {
      if (!_matchesAny(allowed, dependency)) {
        violations.add(
          '${_reported(product, relative)}: dependency $dependency is not '
          'in its allowlist',
        );
      }
    }
  }

  if (!package.pure) return violations;

  final name = package.name!;
  if (package.forbidden.isNotEmpty && package.graph.contains(name)) {
    final trail = await package.graph.forbiddenDependency(
      name,
      (dependency) => _matchesAny(package.forbidden, dependency),
    );
    if (trail != null) {
      violations.add(
        '${_reported(product, relative)}: forbidden transitive dependency '
        '$trail',
      );
    }
  }

  for (final manifest in manifests) {
    if (requiresFlutter(manifest) ||
        dependencySections.any((section) => hasFlutterSdk(manifest, section))) {
      violations.add(
        '${_reported(product, relative)}: Flutter/plugin declaration in a '
        'pure-Dart package',
      );
      continue;
    }
    for (final dependency in dependencyNames(
      manifest,
      dependencySections,
    ).toSet()) {
      final forbidden = await package.graph.flutterDependency(dependency);
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

/// Checks dartssh2 declarations per section: a full dependent may declare
/// it anywhere, a dev dependent only under `dev_dependencies`, and every
/// other package not at all.
void _checkDartssh2Dependencies(
  Map<String, Object?> manifest,
  _ScannedPackage package,
  ProductGuard product,
  List<String> violations,
) {
  final relative = package.relative;
  if (product.allowsDartssh2Dependency(relative)) return;

  for (final section in dependencySections) {
    if (!dependencyNames(manifest, [section]).contains('dartssh2')) continue;
    if (section == 'dev_dependencies' &&
        product.allowsDartssh2DevDependency(relative)) {
      continue;
    }
    violations.add(
      '${_reported(product, relative)}: dartssh2 dependency outside '
      '${_dartssh2DependentName(product)}',
    );
  }
}

String _dartssh2DependentName(ProductGuard product) =>
    product.dartssh2Dependents.isEmpty
    ? 'the configured dartssh2 dependents'
    : p.posix.basename(product.dartssh2Dependents.first);

Future<List<String>> _checkSource(
  File file,
  String relative,
  ProductGuard product,
  _ScannedPackage? package,
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
      final packageName = uri.scheme == 'package'
          ? uri.pathSegments.first
          : null;
      if (packageName == 'dartssh2' &&
          !product.allowsDartssh2Import(relative) &&
          !product.isImportExempt(relative)) {
        violations.add(
          '${_reported(product, relative)}: dartssh2 import/export outside '
          '${_dartssh2ImportArea(product)}',
        );
      }
      if (uri.scheme == 'dart' &&
          uri.path == 'io' &&
          product.forbidsDartIo(relative)) {
        violations.add(
          '${_reported(product, relative)}: dart:io import/export is '
          'forbidden here',
        );
      }
      if (packageName == 'seance_core' &&
          uri.pathSegments.length > 1 &&
          uri.pathSegments[1] == 'src' &&
          !product.allowsSeanceCoreImplementationImport(relative)) {
        violations.add(
          '${_reported(product, relative)}: seance_core implementation '
          'import/export $uri',
        );
      }
      if (packageName != null &&
          package != null &&
          _matchesAny(package.forbidden, packageName)) {
        violations.add(
          '${_reported(product, relative)}: forbidden import/export '
          '$packageName',
        );
      }
      if (packageName != null &&
          package != null &&
          package.allowed != null &&
          packageName != package.name &&
          p.posix.isWithin(p.posix.join(package.relative, 'lib'), relative) &&
          !_matchesAny(package.allowed!, packageName)) {
        violations.add(
          '${_reported(product, relative)}: import/export $packageName is '
          'not in its allowlist',
        );
      }
      if (!_insidePurePackage(product, relative)) continue;

      if (uri.scheme == 'dart' && (uri.path == 'ui' || uri.path == 'ui_web')) {
        violations.add(
          '${_reported(product, relative)}: Flutter SDK import/export $uri',
        );
        continue;
      }
      if (packageName == null) continue;
      if (package == null) {
        throw StateError('Pure package not scanned for: $relative');
      }
      final forbidden = await package.graph.flutterDependency(packageName);
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

/// The sections an allowlist limits; development dependencies serve
/// tests and tooling only.
const _runtimeDependencySections = ['dependencies', 'dependency_overrides'];

bool _matchesAny(Set<String> patterns, String name) =>
    patterns.any((pattern) => packageNameMatches(pattern, name));

/// One scanned package: its manifests, purity, resolution and the
/// forbidden patterns and allowlist its name selects.
class _ScannedPackage {
  const _ScannedPackage({
    required this.directory,
    required this.relative,
    required this.name,
    required this.pubspec,
    required this.overrides,
    required this.pure,
    required this.graph,
    required this.forbidden,
    required this.allowed,
  });

  final Directory directory;
  final String relative;
  final String? name;
  final Map<String, Object?> pubspec;
  final Map<String, Object?>? overrides;
  final bool pure;
  final DependencyGraph graph;
  final Set<String> forbidden;
  final Set<String>? allowed;
}
