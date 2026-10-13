// Golden tests for the four platform fixture shapes (03 §6.5). Each
// fixture directory holds hand-written collector payloads plus a
// `<collector>.golden.json` per payload; `tool/regen_goldens.dart`
// rewrites the goldens. Fixture provenance is in each SOURCE.md.
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
      containsAll(<String>['debian-12', 'ubuntu-2404', 'rhel-8', 'alpine-322']),
    );
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
        expect(result, equals(_golden('$root/$platform/probe.golden.json')));
      });
    });
  }
}

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
