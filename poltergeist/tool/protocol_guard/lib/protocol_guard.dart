import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:path/path.dart' as p;

// The guards are tool directories, not packages, so the shared walk is
// imported by path.
// ignore: avoid_relative_lib_imports
import '../../import_guard/lib/source_walker.dart';

const _engineDirectory = 'packages/poltergeist_core/lib/src/engine';
const _protocolBases = {'EngineRequest', 'EngineEvent'};

// These owners run inside the engine; their callbacks are never payloads.
const _callbackOwners = {
  '$_engineDirectory/progress_coalescer.dart': {'ProgressCoalescer'},
  '$_engineDirectory/connect_log_coalescer.dart': {'ConnectLogCoalescer'},
  '$_engineDirectory/engine_probes.dart': {'EngineProbes'},
};

/// Enforces 08 §3.3 using resolved types, including typedefs and inference.
Future<List<String>> checkProtocol(String rootPath) async {
  final root = p.normalize(p.absolute(rootPath));
  final engine = Directory(p.join(root, _engineDirectory));
  await _requireDirectory(engine);

  final files = <File>[];
  final areas = ['packages', 'app'].map((area) => p.join(root, area)).toList();
  for (final area in areas) {
    final directory = Directory(area);
    await _requireDirectory(directory);
    files.addAll(await dartSources(directory, root).toList());
  }
  if (!files.any((file) => p.isWithin(engine.path, file.path))) {
    throw const FormatException('No engine sources found');
  }

  final contexts = AnalysisContextCollection(includedPaths: areas);
  final violations = <String>[];
  try {
    for (final file in files) {
      violations.addAll(await _checkSource(file, root, contexts));
    }
  } finally {
    await contexts.dispose();
  }
  return violations..sort();
}

Future<List<String>> _checkSource(
  File file,
  String root,
  AnalysisContextCollection contexts,
) async {
  final relative = relativeSourcePath(file.path, root);
  // Parsing separately fails closed even when Flutter imports cannot resolve
  // in the pure-Dart CI job. Engine field types must resolve completely.
  parseString(content: await file.readAsString(), path: file.path);
  final session = contexts.contextFor(file.path).currentSession;
  final result = await session.getResolvedUnit(file.path);
  if (result is! ResolvedUnitResult) {
    throw StateError('Could not resolve $relative: $result');
  }
  final inEngine = p.posix.isWithin(_engineDirectory, relative);
  if (inEngine) {
    final errors = result.diagnostics.where(
      (error) => error.severity == Severity.error,
    );
    if (errors.isNotEmpty) {
      throw FormatException('Could not resolve $relative: ${errors.first}');
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
        violations.add('$relative: ${element.name} is outside engine/');
      }
      continue;
    }

    // An allowed internal helper cannot later become a protocol subtype.
    final allowed = _callbackOwners[relative]?.contains(element.name) ?? false;
    if (allowed && !isPayload) continue;
    for (final field in _callbackFields(element)) {
      violations.add(
        '$relative: ${element.name}.$field has a function-typed field',
      );
    }
  }
  return violations;
}

Set<String> _callbackFields(InterfaceElement element) {
  final callbacks = <String>{};
  for (final owner in _fieldOwners(element.thisType, {})) {
    for (final field in owner.element.fields) {
      if (field.isOriginGetterSetter) continue;
      if (field.isStatic && owner.element != element) continue;

      final name = field.name;
      if (name == null) {
        throw StateError('Unnamed field on ${owner.element.name}');
      }
      // Instantiated getters substitute Base<T>.field when T is a callback.
      final type = owner.getGetter(name)?.returnType ?? field.type;
      if (_containsFunction(type, {})) callbacks.add(name);
    }
  }
  return callbacks;
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
bool _containsFunction(DartType declaredType, Set<DartType> visited) {
  // Extension values carry their representation, including nested wrappers.
  final type = declaredType.extensionTypeErasure;
  if (!visited.add(type)) return false;
  if (type is FunctionType || type.isDartCoreFunction) return true;
  return switch (type) {
    InterfaceType() => type.typeArguments.any(
      (argument) => _containsFunction(argument, visited),
    ),
    RecordType() => [
      ...type.positionalFields,
      ...type.namedFields,
    ].any((field) => _containsFunction(field.type, visited)),
    TypeParameterType() => _containsFunction(type.bound, visited),
    _ => false,
  };
}

Future<void> _requireDirectory(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException('Missing or linked scan root', directory.path);
  }
}
