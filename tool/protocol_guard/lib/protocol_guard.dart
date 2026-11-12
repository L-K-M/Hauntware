import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:path/path.dart' as p;

// The guards are tool directories, not packages, so the shared walk and
// the guards.yaml loader are imported by path.
// ignore: avoid_relative_lib_imports
import '../../import_guard/lib/guards_config.dart';
// ignore: avoid_relative_lib_imports
import '../../import_guard/lib/source_walker.dart';

const _protocolBases = {'EngineRequest', 'EngineEvent'};

/// Enforces 08 §3.3 using resolved types, including typedefs and inference,
/// over the scan areas and engine directory the product's `tool/guards.yaml`
/// entry declares. Reported paths are relative to the repository root.
Future<List<String>> checkProtocol(
  String repositoryRoot,
  ProductGuard product,
) async {
  final root = p.normalize(p.absolute(repositoryRoot));
  final productRoot = p.join(root, product.name);
  final engineRel = product.engineProtocol;
  // A null engine_protocol marks a product with no engine (Séance and
  // Planchette). The config requires the key, so null is declared, not
  // missing.
  if (engineRel == null) return const [];
  final engine = Directory(p.join(productRoot, engineRel));
  await _requireDirectory(engine);

  final files = <File>[];
  final areas = [for (final area in product.scan) p.join(productRoot, area)];
  for (final area in areas) {
    final directory = Directory(area);
    await _requireDirectory(directory);
    files.addAll(
      await dartSources(directory, productRoot, product.scanAreas).toList(),
    );
  }
  if (!files.any((file) => p.isWithin(engine.path, file.path))) {
    throw const FormatException('No engine sources found');
  }

  final contexts = AnalysisContextCollection(includedPaths: areas);
  final violations = <String>[];
  try {
    for (final file in files) {
      violations.addAll(
        await _checkSource(file, productRoot, product, contexts),
      );
    }
  } finally {
    await contexts.dispose();
  }
  return violations..sort();
}

Future<List<String>> _checkSource(
  File file,
  String productRoot,
  ProductGuard product,
  AnalysisContextCollection contexts,
) async {
  final relative = relativeSourcePath(file.path, productRoot);
  final reported = '${product.name}/$relative';
  // Parsing separately fails closed even when Flutter imports cannot resolve
  // in the pure-Dart CI job. Engine field types must resolve completely.
  parseString(content: await file.readAsString(), path: file.path);
  final session = contexts.contextFor(file.path).currentSession;
  final result = await session.getResolvedUnit(file.path);
  if (result is! ResolvedUnitResult) {
    throw StateError('Could not resolve $reported: $result');
  }
  final inEngine = p.posix.isWithin(product.engineProtocol!, relative);
  if (inEngine) {
    final errors = result.diagnostics.where(
      (error) => error.severity == Severity.error,
    );
    if (errors.isNotEmpty) {
      throw FormatException('Could not resolve $reported: ${errors.first}');
    }
  }

  final violations = <String>[];
  for (final declaration in result.unit.declarations) {
    final element = switch (declaration) {
      ClassDeclaration() => declaration.declaredFragment?.element,
      ClassTypeAlias() => declaration.declaredFragment?.element,
      MixinDeclaration() => declaration.declaredFragment?.element,
      EnumDeclaration() => declaration.declaredFragment?.element,
      ExtensionTypeDeclaration() => declaration.declaredFragment?.element,
      _ => null,
    };
    if (element == null) continue;

    final isPayload =
        _protocolBases.contains(element.name) ||
        element.allSupertypes.any(
          (type) => _protocolBases.contains(type.element.name),
        );
    if (!inEngine) {
      if (isPayload) {
        violations.add('$reported: ${element.name} is outside engine/');
      }
      continue;
    }

    // An allowed internal helper cannot later become a protocol subtype.
    final allowed =
        product.engineProtocolCallbackOwners[relative]?.contains(
          element.name,
        ) ??
        false;
    if (allowed && !isPayload) continue;
    // Only a payload is followed into the product's classes: engine-side
    // services (EngineHost) legitimately hold the callback owners above.
    for (final field in _callbackFields(
      element,
      isPayload ? productRoot : null,
    )) {
      violations.add(
        '$reported: ${element.name}.$field has a function-typed field',
      );
    }
  }
  return violations;
}

Set<String> _callbackFields(InterfaceElement element, String? productRoot) {
  final callbacks = <String>{};
  for (final owner in _fieldOwners(element.thisType, {})) {
    for (final (name, type) in _storedFields(
      owner,
      includeStatic: owner.element == element,
    )) {
      if (_containsFunction(type, {}, productRoot)) callbacks.add(name);
    }
  }
  return callbacks;
}

// The fields [owner] itself declares, typed as [owner] instantiates them.
Iterable<(String, DartType)> _storedFields(
  InterfaceType owner, {
  required bool includeStatic,
}) sync* {
  for (final field in owner.element.fields) {
    if (field.isOriginGetterSetter) continue;
    if (field.isStatic && !includeStatic) continue;

    final name = field.name;
    if (name == null) {
      throw StateError('Unnamed field on ${owner.element.name}');
    }
    // Instantiated getters substitute Base<T>.field when T is a callback.
    yield (name, owner.getGetter(name)?.returnType ?? field.type);
  }
}

// Superclasses and applied mixins retain storage, even behind an overridden
// getter. Implemented interfaces and mixin constraints add no instance fields.
Iterable<InterfaceType> _fieldOwners(
  InterfaceType type,
  Set<InterfaceElement> visited,
) sync* {
  if (!visited.add(type.element)) return;
  yield type;
  if (type.superclass case final superclass?) {
    yield* _fieldOwners(superclass, visited);
  }
  for (final mixin in type.mixins) {
    yield* _fieldOwners(mixin, visited);
  }
}

// Generic and record fields can carry callbacks as readily as direct fields.
// With a [productRoot], so can a class the product declares, through its own
// instance fields (`final CallbackBox box;` holding `final void Function()
// run;`). Classes from the SDK and other packages are judged by their type
// arguments only.
bool _containsFunction(
  DartType declaredType,
  Set<DartType> visited,
  String? productRoot,
) {
  // Extension values carry their representation, including nested wrappers.
  final type = declaredType.extensionTypeErasure;
  if (!visited.add(type)) return false;
  if (type is FunctionType || type.isDartCoreFunction) return true;
  bool contains(DartType inner) =>
      _containsFunction(inner, visited, productRoot);
  return switch (type) {
    InterfaceType() =>
      type.typeArguments.any(contains) ||
          (_declaredIn(type.element, productRoot) &&
              _fieldOwners(type, {}).any(
                (owner) => _storedFields(
                  owner,
                  includeStatic: false,
                ).any((field) => contains(field.$2)),
              )),
    RecordType() => [
      ...type.positionalFields,
      ...type.namedFields,
    ].any((field) => contains(field.type)),
    TypeParameterType() => contains(type.bound),
    _ => false,
  };
}

bool _declaredIn(InterfaceElement element, String? productRoot) =>
    productRoot != null &&
    p.isWithin(productRoot, element.library.firstFragment.source.fullName);

Future<void> _requireDirectory(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException('Missing or linked scan root', directory.path);
  }
}
