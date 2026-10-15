// Golden tests for the platform fixture shapes (03 §6.5). Each
// fixture directory holds hand-written collector payloads plus a
// `<collector>.golden.json` per payload; `tool/regen_goldens.dart`
// rewrites the goldens. Fixture provenance is in each SOURCE.md. The
// jobs list built from these fixtures has its golden in
// klabautermann_core, whose zone database the next runs need (D57).
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _ctx = ParseContext.standard;

/// The fixture root, resolved for both `dart test` in the package directory
/// and `dart test packages/klabautermann_host` from the workspace root.
String _fixturesRoot() {
  for (final path in const [
    'test/fixtures',
    'packages/klabautermann_host/test/fixtures',
  ]) {
    if (Directory(path).existsSync()) return path;
  }
  return 'test/fixtures';
}

void main() {
  final root = _fixturesRoot();
  final platforms =
      Directory(root)
          .listSync()
          .whereType<Directory>()
          .map((d) => d.uri.pathSegments[d.uri.pathSegments.length - 2])
          .toList()
        ..sort();
  test('fixture platforms present', () {
    expect(
      platforms,
      containsAll(<String>[
        'debian-12',
        'ubuntu-2404',
        'rhel-8',
        'alpine-322',
        'debian-12-lxc',
        'debian-12-lxc-lxcfs',
      ]),
    );
  });

  group('LXC (D50)', () {
    test('without lxcfs every system-wide file shows host figures', () {
      final p = _profile(root, 'debian-12-lxc');
      expect(p.lxcfsMounts, isEmpty);
      for (final f in SystemWideProcFile.values) {
        expect(p.showsHostFigures(f), isTrue, reason: f.path);
      }
    });

    test('with lxcfs only meminfo and uptime are its own', () {
      final p = _profile(root, 'debian-12-lxc-lxcfs');
      expect(
        [
          for (final f in SystemWideProcFile.values)
            if (p.showsHostFigures(f)!) f,
        ],
        [
          SystemWideProcFile.stat,
          SystemWideProcFile.loadavg,
          SystemWideProcFile.diskstats,
          SystemWideProcFile.pressureCpu,
          SystemWideProcFile.pressureIo,
          SystemWideProcFile.pressureMemory,
        ],
      );
    });

    test('a VM fixture shows its own figures', () {
      final p = _profile(root, 'debian-12');
      for (final f in SystemWideProcFile.values) {
        expect(p.showsHostFigures(f), isFalse, reason: f.path);
      }
    });
  });

  for (final platform in platforms) {
    group(platform, () {
      for (final collector in [
        'overview',
        'core',
        'fs',
        'identity',
        'procs',
        'units',
        'timers',
        'cron',
      ]) {
        test(collector, () {
          final payload = File(
            '$root/$platform/$collector.txt',
          ).readAsStringSync();
          final result = switch (collector) {
            'overview' => parseOverview(payload, _ctx).toJsonResult(),
            'core' => parseCore(payload, _ctx).toJsonResult(),
            'fs' => parseFs(payload, _ctx).toJsonResult(),
            'identity' => parseIdentity(payload, _ctx).toJsonResult(),
            'procs' => parseProcs(payload, _ctx).toJsonResult(),
            'units' => parseUnits(payload, _ctx).toJsonResult(),
            'timers' => parseTimers(payload, _ctx).toJsonResult(),
            'cron' => parseCron(payload, _ctx).toJsonResult(),
            _ => throw StateError(collector),
          };
          expect(
            result,
            equals(_golden('$root/$platform/$collector.golden.json')),
          );
        });
      }

      test('probe', () {
        final sections = _probeSections(
          File('$root/$platform/probe.sections').readAsStringSync(),
        );
        final result = parseProbe(sections, _ctx).toJsonResult();
        final golden = _golden('$root/$platform/probe.golden.json');
        expect(result, equals(golden));

        // The device cache's JSON reads back into the same profile.
        final json = (golden! as Map<String, Object?>)['result'];
        expect(
          HostProfile.fromJson(json! as Map<String, Object?>).toJson(),
          json,
        );
      });
    });
  }
}

/// Parses the probe fixture of [platform] into a profile.
HostProfile _profile(String root, String platform) => parseProbe(
  _probeSections(File('$root/$platform/probe.sections').readAsStringSync()),
  _ctx,
).value;

/// The shared `{"result": ..., "warnings": [...]}` golden shape.
extension on ParseResult<Object?> {
  Map<String, Object?> toJsonResult() => {
    'result': _toJson(value),
    'warnings': warnings,
  };
}

Object? _toJson(Object? v) {
  // CoreSnapshot extends OverviewSnapshot and overrides toJson, so the
  // first branch covers both metric collectors.
  if (v is OverviewSnapshot) return v.toJson();
  if (v is FsSnapshot) return v.toJson();
  if (v is IdentitySnapshot) return v.toJson();
  if (v is HostProfile) return v.toJson();
  if (v is ProcsSnapshot) return v.toJson();
  if (v is UnitsSnapshot) return v.toJson();
  if (v is TimersSnapshot) return v.toJson();
  if (v is CronSnapshot) return v.toJson();
  throw ArgumentError(v);
}

Object? _golden(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Object?;

/// Reads the `### <area> <status>` fixture format into probe sections.
List<ProbeSection> _probeSections(String text) {
  final out = <ProbeSection>[];
  String? area;
  SectionStatus status = SectionStatus.ok;
  final payload = StringBuffer();
  void flush() {
    if (area == null) return;
    final p = payload.toString();
    out.add(
      ProbeSection(
        area,
        status,
        p.endsWith('\n') ? p.substring(0, p.length - 1) : p,
      ),
    );
  }

  for (final line in text.split('\n')) {
    if (line.startsWith('### ')) {
      flush();
      final parts = line.substring(4).trim().split(' ');
      area = parts[0];
      status = SectionStatus.values.byName(parts[1]);
      payload.clear();
    } else {
      payload
        ..write(line)
        ..write('\n');
    }
  }
  flush();
  return out;
}
