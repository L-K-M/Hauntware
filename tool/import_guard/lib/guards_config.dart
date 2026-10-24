// Loader and schema for tool/guards.yaml, the per-product guard
// configuration the root import and protocol guards share (03 §3.4).
// The file fails closed: unknown keys and missing required keys are
// errors, never warnings.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'dependency_graph.dart';

const guardsConfigPath = 'tool/guards.yaml';

/// One `products` entry: every path is relative to the product's own
/// directory (the product name is its top-level directory name).
final class ProductGuard {
  const ProductGuard({
    required this.name,
    required this.scan,
    required this.purePackages,
    required this.dartssh2Imports,
    required this.dartssh2Dependents,
    required this.dartssh2DevDependents,
    required this.importExemptions,
    required this.noDartIo,
    required this.forbiddenDependencies,
    required this.allowedDependencies,
    required this.seanceCoreImplementationImports,
    required this.standaloneResolutions,
    required this.engineProtocol,
    required this.engineProtocolCallbackOwners,
  });

  final String name;

  /// Top-level directories the guards scan for packages and sources.
  final List<String> scan;

  /// Package paths the pure-Dart boundary rules apply to; `dir/*` covers
  /// `dir`'s immediate children. Other scanned packages get only the
  /// dartssh2 checks.
  final List<String> purePackages;

  /// Directories allowed to import or export `package:dartssh2`.
  final List<String> dartssh2Imports;

  /// Package directories allowed to declare a `dartssh2` dependency.
  final List<String> dartssh2Dependents;

  /// Package directories allowed to declare `dartssh2` only under
  /// `dev_dependencies` (a runtime or override declaration is a
  /// violation).
  final List<String> dartssh2DevDependents;

  /// Single files exempt from the dartssh2 import rule.
  final List<String> importExemptions;

  /// Directories whose Dart sources must not import `dart:io`, including
  /// conditional imports.
  final List<String> noDartIo;

  /// A map from a package name or glob to the package names or globs it
  /// must not depend on directly or transitively. Every matching key's
  /// list applies.
  final Map<String, List<String>> forbiddenDependencies;

  /// A map from a package name to the package names or globs it may
  /// declare at runtime (`dependencies`, `dependency_overrides`) and
  /// import from `lib/`. Development dependencies are not limited.
  final Map<String, List<String>> allowedDependencies;

  /// Directories allowed to import `package:seance_core/src/...`; every
  /// other file in the product that does is a violation.
  final List<String> seanceCoreImplementationImports;

  /// Package directories resolving through their own package config
  /// outside the product workspace lock.
  final List<String> standaloneResolutions;

  /// The engine protocol directory, or null when the product has none.
  final String? engineProtocol;

  /// Engine files allowed to hold function-typed fields, mapped to the
  /// internal class names that may hold them.
  final Map<String, List<String>> engineProtocolCallbackOwners;

  Set<String> get scanAreas => scan.toSet();

  /// Whether [packagePath] (relative to the product directory) is pure.
  bool isPurePackage(String packagePath) =>
      purePackages.any((entry) => _pathMatches(entry, packagePath));

  /// Whether [relative] (product-relative) sits inside a configured
  /// dartssh2 import area.
  bool allowsDartssh2Import(String relative) =>
      dartssh2Imports.any((dir) => p.posix.isWithin(dir, relative));

  /// Whether [packagePath] may declare dartssh2 under any dependency
  /// section.
  bool allowsDartssh2Dependency(String packagePath) =>
      dartssh2Dependents.contains(packagePath);

  /// Whether [packagePath] may declare dartssh2 only under
  /// `dev_dependencies`.
  bool allowsDartssh2DevDependency(String packagePath) =>
      dartssh2DevDependents.contains(packagePath);

  /// Whether [relative] (product-relative file path) is exempt from the
  /// dartssh2 import rule.
  bool isImportExempt(String relative) => importExemptions.contains(relative);

  /// Whether [relative] (product-relative) sits inside a `no_dart_io`
  /// directory.
  bool forbidsDartIo(String relative) =>
      noDartIo.any((dir) => p.posix.isWithin(dir, relative));

  /// Whether [relative] (product-relative) sits inside a directory allowed
  /// to import `package:seance_core/src/...`.
  bool allowsSeanceCoreImplementationImport(String relative) =>
      seanceCoreImplementationImports.any(
        (dir) => p.posix.isWithin(dir, relative),
      );

  /// The forbidden dependency patterns that apply to [packageName]: the
  /// union of every key's list whose key matches the name.
  Set<String> forbiddenDependenciesFor(String packageName) {
    final patterns = <String>{};
    for (final entry in forbiddenDependencies.entries) {
      if (packageNameMatches(entry.key, packageName)) {
        patterns.addAll(entry.value);
      }
    }
    return patterns;
  }

  /// The patterns [packageName] may depend on, or null when it has no
  /// allowlist.
  Set<String>? allowedDependenciesFor(String packageName) =>
      allowedDependencies[packageName]?.toSet();
}

/// Whether the package [name] matches [pattern], where `*` matches any
/// run of characters (`ghost_*` matches `ghost_ui`).
bool packageNameMatches(String pattern, String name) {
  if (!pattern.contains('*')) return pattern == name;
  final regex = RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$');
  return regex.hasMatch(name);
}

final class GuardsConfig {
  GuardsConfig._(this.products);

  /// Products in file order, keyed by directory name.
  final Map<String, ProductGuard> products;

  ProductGuard product(String name) {
    final product = products[name];
    if (product == null) {
      throw FormatException('$guardsConfigPath: unknown product "$name"');
    }
    return product;
  }

  static GuardsConfig parse(Object? document, {required String source}) {
    final root = _expectMap(document, source, required: true)!;
    _rejectUnknownKeys(root, const {'products'}, source);
    final products = _expectMap(
      root['products'],
      '$source: products',
      required: true,
    )!;
    if (products.isEmpty) {
      throw FormatException('$source: products must not be empty');
    }

    return GuardsConfig._({
      for (final entry in products.entries)
        if (_productName(entry.key, source) case final name)
          name: _parseProduct(name, entry.value, source),
    });
  }
}

Future<GuardsConfig> loadGuardsConfig(File file) async {
  final yaml = await readPubspec(file);
  return GuardsConfig.parse(yaml, source: file.path);
}

/// Parses `--product <name>` / `--product=<name>`; returns null when the
/// argument list is empty so the caller checks every configured product.
String? parseProductArgument(List<String> arguments) {
  if (arguments.isEmpty) return null;
  if (arguments.length == 2 && arguments.first == '--product') {
    final name = arguments[1];
    if (name.isNotEmpty && !name.startsWith('-')) return name;
  }
  if (arguments.length == 1 && arguments.first.startsWith('--product=')) {
    final name = arguments.first.substring('--product='.length);
    if (name.isNotEmpty) return name;
  }
  throw const FormatException('usage: check.dart [--product <name>]');
}

String _productName(Object? key, String source) {
  if (key is! String || !_isPathSegment(key)) {
    throw FormatException('$source: invalid product name "$key"');
  }
  return key;
}

const _requiredProductKeys = {
  'scan',
  'pure_packages',
  'dartssh2_imports',
  'dartssh2_dependents',
  'engine_protocol',
  'engine_protocol_callback_owners',
};
const _optionalProductKeys = {
  'standalone_resolutions',
  'dartssh2_dev_dependents',
  'import_exemptions',
  'no_dart_io',
  'forbidden_dependencies',
  'allowed_dependencies',
  'seance_core_implementation_imports',
};
const _productKeys = {..._requiredProductKeys, ..._optionalProductKeys};

ProductGuard _parseProduct(String name, Object? value, String source) {
  final label = '$source: products.$name';
  final map = _expectMap(value, label, required: true)!;
  _rejectUnknownKeys(map, _productKeys, label);
  for (final key in _requiredProductKeys) {
    if (!map.containsKey(key)) {
      throw FormatException('$label: missing required key $key');
    }
    // A null list would read as "nothing allowed" or "nothing scanned";
    // only engine_protocol has a meaningful null.
    if (map[key] == null && key != 'engine_protocol') {
      throw FormatException('$label: $key must not be null');
    }
  }

  final scan = _stringList(map['scan'], '$label.scan', required: true);
  if (scan.any((area) => !_isPathSegment(area))) {
    throw FormatException('$label.scan: entries must be single path segments');
  }

  final engineProtocol = _optionalPath(
    map['engine_protocol'],
    '$label.engine_protocol',
  );
  final callbackOwners = _callbackOwners(
    map['engine_protocol_callback_owners'],
    '$label.engine_protocol_callback_owners',
  );
  _checkCallbackOwners(engineProtocol, callbackOwners, label);

  return ProductGuard(
    name: name,
    scan: scan,
    purePackages: _pathList(map['pure_packages'], '$label.pure_packages'),
    dartssh2Imports: _pathList(
      map['dartssh2_imports'],
      '$label.dartssh2_imports',
    ),
    dartssh2Dependents: _pathList(
      map['dartssh2_dependents'],
      '$label.dartssh2_dependents',
    ),
    dartssh2DevDependents: _pathList(
      map['dartssh2_dev_dependents'],
      '$label.dartssh2_dev_dependents',
    ),
    importExemptions: _pathList(
      map['import_exemptions'],
      '$label.import_exemptions',
    ),
    noDartIo: _pathList(map['no_dart_io'], '$label.no_dart_io'),
    forbiddenDependencies: _forbiddenDependencies(
      map['forbidden_dependencies'],
      '$label.forbidden_dependencies',
    ),
    allowedDependencies: _allowedDependencies(
      map['allowed_dependencies'],
      '$label.allowed_dependencies',
    ),
    seanceCoreImplementationImports: _pathList(
      map['seance_core_implementation_imports'],
      '$label.seance_core_implementation_imports',
    ),
    standaloneResolutions: _pathList(
      map['standalone_resolutions'],
      '$label.standalone_resolutions',
    ),
    engineProtocol: engineProtocol,
    engineProtocolCallbackOwners: callbackOwners,
  );
}

/// `forbidden_dependencies` is a map from a package name or glob to the
/// package names or globs it must not depend on. Both sides are validated
/// as package patterns so a malformed glob cannot silently match nothing.
Map<String, List<String>> _forbiddenDependencies(Object? value, String label) {
  final map = _expectMap(value, label);
  if (map == null) return const {};
  final result = <String, List<String>>{};
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw FormatException('$label: keys must be package names or globs');
    }
    _checkPackagePattern(key, label);
    final patterns = _stringList(entry.value, '$label.$key');
    for (final pattern in patterns) {
      _checkPackagePattern(pattern, '$label.$key');
    }
    result[key] = patterns;
  }
  return result;
}

/// `allowed_dependencies` is a map from a package name to the package
/// names or globs it may depend on. Keys are exact names: two globs
/// matching one package would leave its allowlist ambiguous.
Map<String, List<String>> _allowedDependencies(Object? value, String label) {
  final patterns = _forbiddenDependencies(value, label);
  for (final key in patterns.keys) {
    if (key.contains('*')) {
      throw FormatException('$label: "$key" must be a package name');
    }
  }
  return patterns;
}

/// Package patterns are `[A-Za-z0-9_]` with an optional `*` wildcard, and
/// must not start with `*` so an accidental global ban fails closed.
void _checkPackagePattern(String pattern, String label) {
  if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_*]*$').hasMatch(pattern)) {
    throw FormatException('$label: invalid package pattern "$pattern"');
  }
}

/// Callback owners are exceptions inside the engine protocol directory;
/// one outside it, or without a directory, would exempt nothing.
void _checkCallbackOwners(
  String? engineProtocol,
  Map<String, List<String>> owners,
  String label,
) {
  final ownersLabel = '$label.engine_protocol_callback_owners';
  if (engineProtocol == null) {
    if (owners.isNotEmpty) {
      throw FormatException(
        '$ownersLabel: must be empty when engine_protocol is null',
      );
    }
    return;
  }
  for (final file in owners.keys) {
    if (!p.posix.isWithin(engineProtocol, file)) {
      throw FormatException(
        '$ownersLabel: "$file" is outside engine_protocol "$engineProtocol"',
      );
    }
  }
}

void _rejectUnknownKeys(
  Map<Object?, Object?> map,
  Set<String> allowed,
  String label,
) {
  for (final key in map.keys) {
    if (key is! String || !allowed.contains(key)) {
      throw FormatException('$label: unknown key "$key"');
    }
  }
}

Map<Object?, Object?>? _expectMap(
  Object? value,
  String label, {
  bool required = false,
}) {
  if (value == null) {
    if (required) throw FormatException('$label: missing required key');
    return null;
  }
  if (value is! Map) {
    throw FormatException('$label: expected a map');
  }
  return value;
}

List<String> _stringList(Object? value, String label, {bool required = false}) {
  if (value == null) {
    if (required) throw FormatException('$label: missing');
    return const [];
  }
  if (value is! List || value.any((item) => item is! String || item.isEmpty)) {
    throw FormatException('$label: expected a list of non-empty strings');
  }
  if (required && value.isEmpty) {
    throw FormatException('$label: must not be empty');
  }
  return value.cast<String>();
}

/// Paths must be relative, `/`-separated and single-segment-clean so they
/// line up with the paths the guards compute.
List<String> _pathList(Object? value, String label) {
  final paths = _stringList(value, label);
  for (final path in paths) {
    _checkPath(
      path.endsWith('/*') ? path.substring(0, path.length - 2) : path,
      label,
    );
  }
  return paths;
}

String? _optionalPath(Object? value, String label) {
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$label: expected a path or null');
  }
  _checkPath(value, label);
  return value;
}

/// The only wildcard is a trailing `/*`, which [_pathList] strips before
/// calling this; any other `*` would match nothing and silently weaken a
/// rule, so it fails closed.
void _checkPath(String path, String label) {
  if (path.isEmpty ||
      path.contains('*') ||
      path.startsWith('/') ||
      path.endsWith('/') ||
      path.contains('//') ||
      path.contains('\\') ||
      p.posix.split(path).any((part) => part == '.' || part == '..')) {
    throw FormatException('$label: invalid relative path "$path"');
  }
}

bool _isPathSegment(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.contains('\\') &&
    p.posix.basename(name) == name;

Map<String, List<String>> _callbackOwners(Object? value, String label) {
  final map = _expectMap(value, label, required: true)!;
  return {
    for (final entry in map.entries)
      () {
        final key = entry.key;
        if (key is! String) {
          throw FormatException('$label: keys must be file paths');
        }
        _checkPath(key, label);
        return key;
      }(): _stringList(
        entry.value,
        '$label.${entry.key}',
      ),
  };
}

bool _pathMatches(String entry, String path) {
  if (!entry.endsWith('/*')) return entry == path;
  final prefix = entry.substring(0, entry.length - 2);
  return p.posix.dirname(path) == prefix;
}
