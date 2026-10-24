// The CI tool stays outside the shipped packages.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../lib/guards_config.dart';
import '../lib/import_guard.dart';

// The fixture reproduces the monorepo layout: the generalized guard runs
// from a repository root against the `poltergeist` product entry, so the
// verdicts below are the ones the pre-move guard produced, with every
// reported path gaining its `poltergeist/` prefix.
const _product = 'poltergeist';
const _core = '$_product/packages/poltergeist_core';
const _app = '$_product/app/poltergeist_app';

// Exercises every extended rule key against the same monorepo-shaped
// fixture. The forbidden target is a neutral package so only the
// forbidden-dependency rule fires.
const _extendedGuardsConfig = '''
products:
  poltergeist:
    scan: [packages, app]
    pure_packages: [packages/*]
    dartssh2_imports:
      - packages/poltergeist_core/lib/src/connection
      - packages/poltergeist_bench
    dartssh2_dependents:
      - packages/poltergeist_core
      - packages/poltergeist_bench
    dartssh2_dev_dependents:
      - app/poltergeist_app
    import_exemptions:
      - app/poltergeist_app/lib/exempt.dart
    no_dart_io:
      - packages/poltergeist_core/lib
    forbidden_dependencies:
      poltergeist_sync: [bridge]
    allowed_dependencies:
      poltergeist_view: [meta, "path*"]
    seance_core_implementation_imports:
      - packages/poltergeist_core/lib/src/connection
    standalone_resolutions:
      - packages/poltergeist_bench
    engine_protocol: packages/poltergeist_core/lib/src/engine
    engine_protocol_callback_owners: {}
''';

void main() {
  late _Fixture fixture;

  setUp(() async => fixture = await _Fixture.create());
  tearDown(() async => fixture.root.delete(recursive: true));

  test('accepts connection imports and Flutter app code', () async {
    await fixture.write(
      '$_core/lib/src/connection/ssh.dart',
      "import 'package:dartssh2/dartssh2.dart';",
    );
    await fixture.write(
      '$_app/lib/main.dart',
      "import 'package:flutter/material.dart';",
    );
    await fixture.expectExit(0);
    await fixture.expectScriptExit(0);
  });

  for (final source in [
    "import 'package:dartssh2/dartssh2.dart';",
    "export 'package:dartssh2/dartssh2.dart';",
    r"import 'package:dart\u0073sh2/dartssh2.dart';",
    "import 'safe.dart' if (dart.library.io) 'package:dartssh2/dartssh2.dart';",
  ]) {
    test('rejects SSH outside connection: $source', () async {
      await fixture.write('$_app/lib/main.dart', source);
      await fixture.expectExit(1, 'dartssh2');
    });
  }

  test('reports violations with the product path prefix', () async {
    await fixture.write(
      '$_product/packages/poltergeist_sync/pubspec.yaml',
      'name: poltergeist_sync',
    );
    await fixture._register(
      'poltergeist_sync',
      '$_product/packages/poltergeist_sync',
    );
    await fixture.write(
      '$_product/packages/poltergeist_sync/lib/sync.dart',
      "import 'package:dartssh2/dartssh2.dart';",
    );
    await fixture.expectExit(
      1,
      'poltergeist/packages/poltergeist_sync/lib/sync.dart: dartssh2 '
      'import/export outside '
      'poltergeist/packages/poltergeist_core/lib/src/connection',
    );
  });

  test('ignores comments and ordinary strings', () async {
    await fixture.write('$_core/lib/example.dart', '''
/*
import 'package:dartssh2/dartssh2.dart';
*/
const example = "package:flutter/widgets.dart";
''');
    await fixture.expectExit(0);
  });

  test('rejects a plugin whose name has no Flutter prefix', () async {
    await fixture.package('native_paths', 'flutter: {plugin: {platforms: {}}}');
    await fixture.write(
      '$_core/lib/example.dart',
      "import 'package:native_paths/native_paths.dart';",
    );
    await fixture.expectExit(1, 'native_paths');
  });

  for (final package in [
    'flutter',
    'flutter_test',
    'flutter_driver',
    'flutter_localizations',
    'flutter_web_plugins',
    'integration_test',
    'sky_engine',
    'flutter_gpu',
  ]) {
    test('reports unresolved SDK package $package as a violation', () async {
      await fixture.write(
        '$_core/lib/core.dart',
        "import 'package:$package/api.dart';",
      );
      await fixture.expectExit(1, package);
    });
  }

  test('missing package configuration gives shell remediation', () async {
    await File(
      p.join(fixture.root.path, '$_product/.dart_tool/package_config.json'),
    ).delete();
    await fixture.expectScriptExit(2, 'run dart pub get');
  });

  test('missing package configuration fails closed with the hint', () async {
    await File(
      p.join(fixture.root.path, '$_product/.dart_tool/package_config.json'),
    ).delete();
    await fixture.expectExit(2, 'run dart pub get');
  });

  test(
    'reports interpolated directives without a null-check failure',
    () async {
      await fixture.write(
        '$_core/lib/core.dart',
        r"import 'package:$name/api.dart';",
      );
      await fixture.expectExit(1, 'non-constant import/export URI');
    },
  );

  test('rejects an unused declared plugin', () async {
    await fixture.package('native_paths', 'flutter: {plugin: {platforms: {}}}');
    await fixture.write('$_core/pubspec.yaml', '''
name: poltergeist_core
dependencies: {native_paths: any}
''');
    await fixture.expectExit(1, 'native_paths');
  });

  test('rejects a transitive Flutter dependency', () async {
    await fixture.package('bridge', 'dependencies: {native_paths: any}');
    await fixture.package(
      'native_paths',
      'dependencies: {flutter: {sdk: flutter}}',
    );
    await fixture.write(
      '$_core/lib/example.dart',
      "export 'package:bridge/bridge.dart';",
    );
    await fixture.expectExit(1, 'native_paths');
  });

  test('rejects inline Flutter SDK declarations', () async {
    await fixture.write('$_core/pubspec.yaml', '''
name: poltergeist_core
dev_dependencies: {flutter_test: {sdk: flutter}}
''');
    await fixture.expectExit(1, 'Flutter');
  });

  test('rejects quoted SSH declarations in app overrides', () async {
    await fixture.write('$_app/pubspec.yaml', '''
name: poltergeist_app
dependency_overrides: {"dartssh2": any}
''');
    await fixture.expectExit(1, 'dartssh2');
  });

  for (final location in [
    '$_core/lib/src/connection_extra/ssh.dart',
    '$_core/test/ssh_test.dart',
    '$_core/lib/core.dart',
    '$_product/packages/poltergeist_sync/lib/sync.dart',
  ]) {
    test('rejects SSH at $location', () async {
      await fixture.write(location, "import 'package:dartssh2/dartssh2.dart';");
      if (location.startsWith('$_product/packages/poltergeist_sync/')) {
        await fixture.write(
          '$_product/packages/poltergeist_sync/pubspec.yaml',
          'name: poltergeist_sync',
        );
        await fixture._register(
          'poltergeist_sync',
          '$_product/packages/poltergeist_sync',
        );
      }
      await fixture.expectExit(1, 'dartssh2');
    });
  }

  for (final source in [
    "export 'dart:ui';",
    "import\n /* note */ 'dart:ui_web';",
    "export 'safe.dart' if (dart.library.ui) 'package:native_paths/paths.dart';",
    "/* note */ import r'package:native_paths/paths.dart';",
  ]) {
    test('rejects Flutter directive: $source', () async {
      await fixture.package(
        'native_paths',
        'flutter: {plugin: {platforms: {}}}',
      );
      await fixture.write('$_core/lib/core.dart', source);
      await fixture.expectExit(1, 'Flutter');
    });
  }

  for (final section in [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ]) {
    test('checks plugins declared in $section', () async {
      await fixture.package(
        'native_paths',
        'environment: {flutter: ">=3.0.0"}',
      );
      await fixture.write(
        '$_core/pubspec.yaml',
        'name: poltergeist_core\n$section: {native_paths: any}',
      );
      await fixture.expectExit(1, 'native_paths');
    });
  }

  test('checks the local override file', () async {
    await fixture.write(
      '$_app/pubspec_overrides.yaml',
      'dependency_overrides: {dartssh2: any}',
    );
    await fixture.expectExit(1, 'dartssh2');
  });

  test(
    'allows external Flutter tests and pure packages with plugin names',
    () async {
      await fixture.package(
        'flutter_example',
        'dev_dependencies: {flutter_test: {sdk: flutter}}',
      );
      await fixture.package(
        'plugin_interface',
        'dependencies: {flutter_example: any}',
      );
      await fixture.write(
        '$_core/lib/core.dart',
        "import 'package:plugin_interface/api.dart';",
      );
      await fixture.expectExit(0);
    },
  );

  test('excludes generated trees and tool/ harnesses', () async {
    for (final directory in ['build', '.dart_tool', '.symlinks', 'ephemeral']) {
      await fixture.write(
        '$_core/$directory/bad.dart',
        "import 'package:dartssh2/dartssh2.dart';",
      );
    }
    await fixture.write(
      '$_product/tool/bench/lib/ssh.dart',
      "import 'package:dartssh2/dartssh2.dart';",
    );
    await fixture.expectExit(0);
  });

  test(
    'accepts the harness dartssh2 consumer through its own resolution',
    () async {
      await fixture.writeBenchHarness(
        pubspec: 'name: poltergeist_m0_bench\ndependencies: {dartssh2: any}\n',
        source: "import 'package:dartssh2/dartssh2.dart';",
      );
      await fixture.expectExit(0);
    },
  );

  test('fails closed without the harness standalone resolution', () async {
    await fixture.writeBenchHarness(
      pubspec: 'name: poltergeist_m0_bench\n',
      source: '// no imports\n',
      writeStandaloneConfig: false,
    );
    await fixture.expectExit(2, 'run dart pub get there');
  });

  test(
    'rejects a harness Flutter dependency through its own resolution',
    () async {
      await fixture.writeBenchHarness(
        pubspec:
            'name: poltergeist_m0_bench\ndependencies: {native_paths: any}\n',
        source: "import 'package:native_paths/native_paths.dart';",
        standaloneDependencies: {
          'native_paths': 'flutter: {plugin: {platforms: {}}}',
        },
      );
      await fixture.expectExit(1, 'native_paths');
    },
  );

  for (final platform in ['ios', 'macos']) {
    test('excludes generated $platform CocoaPods links', () async {
      final headers = Directory(
        p.join(fixture.root.path, '$_app/$platform/Pods/Headers'),
      );
      await headers.create(recursive: true);
      await Link(p.join(headers.path, 'Public')).create('../Generated');
      await fixture.expectExit(0);
    });
  }

  test('does not exclude a Dart source directory named Pods', () async {
    await fixture.write(
      '$_app/lib/Pods/ssh.dart',
      "import 'package:dartssh2/dartssh2.dart';",
    );
    await fixture.expectExit(1, 'dartssh2');
  });

  for (final name in [
    'build',
    'ephemeral',
    '.dart_tool',
    '.symlinks',
    '.git',
  ]) {
    for (final location in ['$_core/lib', '$_core/test', '$_app/lib/src']) {
      test('scans source directory $location/$name', () async {
        await fixture.write(
          '$location/$name/ssh.dart',
          "import 'package:dartssh2/dartssh2.dart';",
        );
        await fixture.expectExit(1, 'dartssh2');
      });
    }
  }

  test('scans a package named build', () async {
    await fixture.write(
      '$_product/packages/build/pubspec.yaml',
      'name: fixture_build',
    );
    await fixture._register('fixture_build', '$_product/packages/build');
    await fixture.write(
      '$_product/packages/build/lib/ssh.dart',
      "import 'package:dartssh2/dartssh2.dart';",
    );
    await fixture.expectExit(1, 'dartssh2');
  });

  test('skips generated native outputs with symlinks', () async {
    for (final output in [
      'linux/flutter/ephemeral',
      'windows/flutter/ephemeral',
      'macos/Flutter/ephemeral',
      'ios/Flutter/ephemeral',
      'ios/.symlinks',
      'macos/.symlinks',
      'android/app/build',
      'android/build',
    ]) {
      final directory = Directory(p.join(fixture.root.path, _app, output));
      await directory.create(recursive: true);
      await Link(p.join(directory.path, 'generated')).create('absent');
    }
    await fixture.expectExit(0);
  });

  test('reports an empty package URI as a violation', () async {
    await fixture.write('$_core/lib/core.dart', "import 'package:';");
    await fixture.expectExit(1, 'invalid package URI');
  });

  test('identifies a missing package name', () async {
    await fixture.write('$_core/pubspec.yaml', 'description: unnamed');
    await fixture.expectExit(2, _core);
  });

  for (final directory in ['packages', 'app']) {
    test('fails closed without $directory', () async {
      await Directory(
        p.join(fixture.root.path, '$_product/$directory'),
      ).delete(recursive: true);
      await fixture.expectExit(2, 'Missing scan root');
    });

    test('fails closed on linked $directory root', () async {
      final path = p.join(fixture.root.path, '$_product/$directory');
      final target = '$path-target';
      await Directory(path).rename(target);
      await Link(path).create(target);

      await fixture.expectExit(2, 'Linked scan root');
    });
  }

  for (final input in [
    '$_product/.dart_tool/package_config.json',
    '$_core/pubspec.yaml',
  ]) {
    test('fails closed without $input', () async {
      await File(p.join(fixture.root.path, input)).delete();
      await fixture.expectExit(2, p.basename(input));
    });
  }

  test('fails closed on malformed YAML through the shell entrypoint', () async {
    await fixture.write('$_core/pubspec.yaml', 'name: [');
    await fixture.expectExit(2);
    await fixture.expectScriptExit(2, 'dependency scan failed');
  });

  test('fails closed on invalid Dart', () async {
    await fixture.write('$_core/lib/core.dart', "import 'unterminated");
    await fixture.expectExit(2);
  });

  test('fails closed on an unresolved import', () async {
    await fixture.write(
      '$_core/lib/core.dart',
      "import 'package:absent/api.dart';",
    );
    await fixture.expectExit(2, 'Unresolved dependency absent');
  });

  test('fails closed on linked source', () async {
    await Link(
      p.join(fixture.root.path, '$_core/lib/link.dart'),
    ).create('core.dart');
    await fixture.expectExit(2, 'Linked scan input');
  });

  test('fails closed on a linked package', () async {
    await fixture.write('linked/lib/ssh.dart', "import 'dart:io';");
    await Link(
      p.join(fixture.root.path, '$_product/packages/linked'),
    ).create(p.join(fixture.root.path, 'linked'));
    await fixture.expectExit(2, 'Linked package');
  });

  // Each CLI check starts a cold Dart VM that loads the analyzer; on a loaded
  // runner that can pass the 30 s default. The assertions are about exit
  // codes, not startup speed.
  group(
    'the CLI',
    () {
      test('accepts a --product selector', () async {
        await fixture.expectCliExit(0, const ['--product', 'poltergeist']);
      });

      test('rejects an unknown product', () async {
        await fixture.expectCliExit(
          2,
          const ['--product', 'unknown'],
          'unknown',
        );
      });

      test('rejects malformed arguments', () async {
        await fixture.expectCliExit(64, const ['positional'], 'usage');
        await fixture.expectCliExit(64, const ['--product'], 'usage');
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  group('extended rules', () {
    Future<void> withFixture(
      Future<void> Function(_Fixture fixture) body,
    ) async {
      final extended = await _Fixture.create(
        guardsConfig: _extendedGuardsConfig,
      );
      // The package allowed_dependencies names; a missing one fails.
      const view = '$_product/packages/poltergeist_view';
      await extended.write('$view/pubspec.yaml', 'name: poltergeist_view\n');
      await extended._register('poltergeist_view', view);
      try {
        await body(extended);
      } finally {
        await extended.root.delete(recursive: true);
      }
    }

    test('allows a dev-only dartssh2 declaration', () async {
      await withFixture((f) async {
        await f.write(
          '$_app/pubspec.yaml',
          'name: poltergeist_app\ndev_dependencies: {dartssh2: any}\n',
        );
        await f.expectExit(0);
      });
    });

    test('rejects a runtime dartssh2 declaration in a dev dependent', () async {
      await withFixture((f) async {
        await f.write(
          '$_app/pubspec.yaml',
          'name: poltergeist_app\ndependencies: {dartssh2: any}\n',
        );
        await f.expectExit(1, 'dartssh2');
      });
    });

    test('rejects an overridden dartssh2 in a dev dependent', () async {
      await withFixture((f) async {
        await f.write(
          '$_app/pubspec_overrides.yaml',
          'dependency_overrides: {dartssh2: any}\n',
        );
        await f.expectExit(1, 'dartssh2');
      });
    });

    test('allows a dartssh2 import in an exempt file', () async {
      await withFixture((f) async {
        await f.write(
          '$_app/lib/exempt.dart',
          "import 'package:dartssh2/dartssh2.dart';",
        );
        await f.expectExit(0);
      });
    });

    test('rejects a dartssh2 import outside the exempt file', () async {
      await withFixture((f) async {
        await f.write(
          '$_app/lib/other.dart',
          "import 'package:dartssh2/dartssh2.dart';",
        );
        await f.expectExit(1, 'dartssh2');
      });
    });

    test('rejects dart:io in a no_dart_io directory', () async {
      await withFixture((f) async {
        await f.write('$_core/lib/src/io.dart', "import 'dart:io';");
        await f.expectExit(1, 'dart:io');
      });
    });

    test('rejects a conditional dart:io import', () async {
      await withFixture((f) async {
        await f.write(
          '$_core/lib/src/io.dart',
          "import 'x.dart' if (dart.library.io) 'dart:io';",
        );
        await f.expectExit(1, 'dart:io');
      });
    });

    test('allows dart:io outside a no_dart_io directory', () async {
      await withFixture((f) async {
        await f.write('$_app/lib/io.dart', "import 'dart:io';");
        await f.expectExit(0);
      });
    });

    test('rejects a forbidden dependency in a pubspec', () async {
      await withFixture((f) async {
        await f.package('bridge', '');
        await f.write(
          '$_product/packages/poltergeist_sync/pubspec.yaml',
          'name: poltergeist_sync\ndependencies: {bridge: any}\n',
        );
        await f._register(
          'poltergeist_sync',
          '$_product/packages/poltergeist_sync',
        );
        await f.expectExit(1, 'forbidden dependency bridge');
      });
    });

    test('accepts a clean pubspec against forbidden dependencies', () async {
      await withFixture((f) async {
        await f.write(
          '$_product/packages/poltergeist_sync/pubspec.yaml',
          'name: poltergeist_sync\n',
        );
        await f._register(
          'poltergeist_sync',
          '$_product/packages/poltergeist_sync',
        );
        await f.expectExit(0);
      });
    });

    test('rejects a forbidden import', () async {
      await withFixture((f) async {
        await f.package('bridge', '');
        await f.write(
          '$_product/packages/poltergeist_sync/pubspec.yaml',
          'name: poltergeist_sync\n',
        );
        await f._register(
          'poltergeist_sync',
          '$_product/packages/poltergeist_sync',
        );
        await f.write(
          '$_product/packages/poltergeist_sync/lib/sync.dart',
          "import 'package:bridge/bridge.dart';",
        );
        await f.expectExit(1, 'forbidden import/export bridge');
      });
    });

    test('rejects a forbidden transitive dependency', () async {
      await withFixture((f) async {
        await f.package('bridge', '');
        await f.package('middle', 'dependencies: {bridge: any}');
        await f.write(
          '$_product/packages/poltergeist_sync/pubspec.yaml',
          'name: poltergeist_sync\ndependencies: {middle: any}\n',
        );
        await f._register(
          'poltergeist_sync',
          '$_product/packages/poltergeist_sync',
        );
        await f.expectExit(
          1,
          'forbidden transitive dependency poltergeist_sync -> middle -> bridge',
        );
      });
    });

    group('allowlist', () {
      const view = '$_product/packages/poltergeist_view';

      Future<void> viewPackage(_Fixture f, String dependencies) async {
        await f.package('meta', '');
        await f.package('path', '');
        await f.package('bridge', '');
        await f.write(
          '$view/pubspec.yaml',
          'name: poltergeist_view\n$dependencies',
        );
        await f._register('poltergeist_view', view);
      }

      test('accepts listed runtime and any dev dependencies', () async {
        await withFixture((f) async {
          await viewPackage(
            f,
            'dependencies: {meta: any, path: any}\n'
            'dev_dependencies: {bridge: any}\n',
          );
          await f.write(
            '$view/lib/view.dart',
            "import 'package:meta/meta.dart';\n"
                "import 'package:path/path.dart';\n"
                "import 'package:poltergeist_view/other.dart';\n"
                "import 'dart:async';",
          );
          await f.write(
            '$view/test/view_test.dart',
            "import 'package:bridge/bridge.dart';",
          );
          await f.expectExit(0);
        });
      });

      for (final section in ['dependencies', 'dependency_overrides']) {
        test('rejects an unlisted package in $section', () async {
          await withFixture((f) async {
            await viewPackage(f, '$section: {bridge: any}\n');
            await f.expectExit(
              1,
              'poltergeist/packages/poltergeist_view: dependency bridge is '
              'not in its allowlist',
            );
          });
        });
      }

      test('rejects an unlisted import from lib', () async {
        await withFixture((f) async {
          await viewPackage(f, '');
          await f.write(
            '$view/lib/view.dart',
            "import 'package:bridge/bridge.dart';",
          );
          await f.expectExit(
            1,
            'poltergeist/packages/poltergeist_view/lib/view.dart: '
            'import/export bridge is not in its allowlist',
          );
        });
      });

      test('rejects a dev-only package imported from lib', () async {
        await withFixture((f) async {
          await viewPackage(f, 'dev_dependencies: {bridge: any}\n');
          await f.write(
            '$view/lib/view.dart',
            "import 'package:bridge/bridge.dart';",
          );
          await f.expectExit(
            1,
            'poltergeist/packages/poltergeist_view/lib/view.dart: '
            'import/export bridge is not in its allowlist',
          );
        });
      });

      test('rejects an allowlist naming no scanned package', () async {
        await withFixture((f) async {
          await Directory(p.join(f.root.path, view)).delete(recursive: true);
          await f.expectExit(
            1,
            'poltergeist: allowed_dependencies names poltergeist_view, '
            'which is not a scanned package',
          );
        });
      });

      test('leaves packages without an allowlist alone', () async {
        await withFixture((f) async {
          await f.package('bridge', '');
          await f.write(
            '$_product/packages/poltergeist_other/pubspec.yaml',
            'name: poltergeist_other\ndependencies: {bridge: any}\n',
          );
          await f._register(
            'poltergeist_other',
            '$_product/packages/poltergeist_other',
          );
          await f.expectExit(0);
        });
      });
    });

    test(
      'allows a seance_core implementation import in an allowed dir',
      () async {
        await withFixture((f) async {
          await f.package('seance_core', '');
          await f.write(
            '$_core/lib/src/connection/ssh.dart',
            "import 'package:seance_core/src/ssh/ssh_session.dart';",
          );
          await f.expectExit(0);
        });
      },
    );

    test(
      'rejects a seance_core implementation import outside allowed dirs',
      () async {
        await withFixture((f) async {
          await f.package('seance_core', '');
          await f.write(
            '$_core/lib/other.dart',
            "import 'package:seance_core/src/ssh/ssh_session.dart';",
          );
          await f.expectExit(1, 'seance_core implementation');
        });
      },
    );
  });
}

class _Fixture {
  _Fixture(this.root, this._config, this.product);

  /// The fixture repository root: `poltergeist/` sits inside it.
  final Directory root;

  /// The product workspace package config entries (root config plus the
  /// registered fixture packages).
  final Map<String, Object?> _config;
  final ProductGuard product;

  static const _guardsConfig = '''
products:
  poltergeist:
    scan: [packages, app]
    pure_packages: [packages/*]
    dartssh2_imports:
      - packages/poltergeist_core/lib/src/connection
      - packages/poltergeist_bench
    dartssh2_dependents:
      - packages/poltergeist_core
      - packages/poltergeist_bench
    standalone_resolutions:
      - packages/poltergeist_bench
    engine_protocol: packages/poltergeist_core/lib/src/engine
    engine_protocol_callback_owners: {}
''';

  static Future<_Fixture> create({
    String guardsConfig = _guardsConfig,
    String product = 'poltergeist',
  }) async {
    final root = await Directory.systemTemp.createTemp('import-guard-');
    // The tool resolves through the repository root's package config,
    // exactly like the real run from the checkout root.
    final configFile = File('.dart_tool/package_config.json').absolute;
    final config =
        jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    final packages = config['packages'] as List<dynamic>;
    for (final entry in packages.cast<Map<String, dynamic>>()) {
      entry['rootUri'] = configFile.uri
          .resolve(entry['rootUri'] as String)
          .toString();
    }
    final fixture = _Fixture(
      root,
      config,
      GuardsConfig.parse(
        loadYaml(guardsConfig),
        source: 'guards.yaml',
      ).product(product),
    );
    await fixture.write('.dart_tool/package_config.json', jsonEncode(config));
    await fixture.write('tool/guards.yaml', guardsConfig);
    await fixture.write(
      '$_product/scripts/check-imports.sh',
      await File('poltergeist/scripts/check-imports.sh').readAsString(),
    );

    // CLI checks invoke the real shell entrypoint from a different directory.
    final tool = Directory('tool/import_guard');
    await for (final file in tool.list(recursive: true)) {
      if (file is! File || p.split(file.path).contains('test')) continue;
      await fixture.write(file.path, await file.readAsString());
    }

    await fixture.write('$_core/pubspec.yaml', 'name: poltergeist_core\n');
    await fixture.write('$_app/pubspec.yaml', 'name: poltergeist_app\n');
    await fixture.write('$_core/lib/core.dart', '// Empty fixture.\n');
    await fixture.write('$_app/lib/main.dart', '// Empty fixture.\n');
    await fixture._register('poltergeist_core', _core);
    // SSH fixture classification must not depend on the workspace's own pin.
    await fixture.package('dartssh2', '');
    return fixture;
  }

  Future<void> write(String path, String contents) async {
    final file = File(p.join(root.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  Future<void> package(String name, String fields) async {
    final path = 'resolved/$name';
    await write('$path/pubspec.yaml', 'name: $name\n$fields\n');
    await _register(name, path);
  }

  /// Writes the relocated M0 harness with its own standalone package config,
  /// mirroring how the real package resolves outside the workspace lock.
  Future<void> writeBenchHarness({
    required String pubspec,
    required String source,
    bool writeStandaloneConfig = true,
    Map<String, String> standaloneDependencies = const {},
  }) async {
    const bench = '$_product/packages/poltergeist_bench';
    await write('$bench/pubspec.yaml', pubspec);
    await write('$bench/lib/ssh.dart', source);
    if (!writeStandaloneConfig) return;

    final entries = <Map<String, Object?>>[
      {
        'name': 'poltergeist_m0_bench',
        'rootUri': Directory(p.join(root.path, bench)).uri.toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.12',
      },
    ];
    for (final entry in standaloneDependencies.entries) {
      final name = entry.key;
      final path = 'resolved/$name';
      await write('$path/pubspec.yaml', 'name: $name\n${entry.value}\n');
      entries.add({
        'name': name,
        'rootUri': Directory(p.join(root.path, path)).uri.toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.12',
      });
    }
    for (final entry
        in (_config['packages'] as List).cast<Map<String, dynamic>>()) {
      if (entry['name'] == 'dartssh2') {
        entries.add(Map<String, Object?>.from(entry));
      }
    }
    await write(
      '$bench/.dart_tool/package_config.json',
      jsonEncode({'configVersion': 2, 'packages': entries}),
    );
  }

  Future<void> _register(String name, String path) async {
    final packages = _config['packages'] as List<dynamic>;
    packages.removeWhere((dynamic entry) => entry['name'] == name);
    packages.add({
      'name': name,
      'rootUri': Directory(p.join(root.path, path)).uri.toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.12',
    });
    await write(
      '$_product/.dart_tool/package_config.json',
      jsonEncode(_config),
    );
  }

  Future<void> expectExit(int code, [String? diagnostic]) async {
    late int actualCode;
    late String output;
    try {
      final violations = await checkImports(root.path, product);
      actualCode = violations.isEmpty ? 0 : 1;
      output = violations.join('\n');
    } catch (error) {
      actualCode = 2;
      output = '$error';
    }
    expect(actualCode, code, reason: output);
    if (diagnostic != null) expect(output, contains(diagnostic));
  }

  Future<void> expectScriptExit(int code, [String? diagnostic]) async {
    final result = await Process.run(
      'bash',
      [p.join(root.path, '$_product/scripts/check-imports.sh')],
      environment: {
        'PATH':
            '${p.dirname(Platform.resolvedExecutable)}'
            '${Platform.isWindows ? ';' : ':'}'
            '${Platform.environment['PATH']}',
      },
    );
    expect(result.exitCode, code, reason: '${result.stdout}\n${result.stderr}');
    if (diagnostic != null) expect(result.stderr, contains(diagnostic));
  }

  Future<void> expectCliExit(
    int code,
    List<String> arguments, [
    String? diagnostic,
  ]) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      '--packages=${p.join(root.path, '.dart_tool/package_config.json')}',
      p.join(root.path, 'tool/import_guard/bin/check.dart'),
      ...arguments,
    ], workingDirectory: root.path);
    expect(result.exitCode, code, reason: '${result.stdout}\n${result.stderr}');
    if (diagnostic != null) expect(result.stderr, contains(diagnostic));
  }
}
