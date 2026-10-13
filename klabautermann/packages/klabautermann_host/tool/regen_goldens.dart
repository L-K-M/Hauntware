// Regenerates `test/fixtures/<platform>/*.golden.json` from the fixture
// payloads. Run from the package directory:
//   dart run tool/regen_goldens.dart
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';

const _ctx = ParseContext.standard;

void main() {
  for (final dir in Directory(
    'test/fixtures',
  ).listSync().whereType<Directory>()) {
    final platform = dir.path.split('/').last;
    for (final collector in ['overview', 'core', 'fs', 'identity']) {
      final payload = File('${dir.path}/$collector.txt').readAsStringSync();
      final result = switch (collector) {
        'overview' => parseOverview(payload, _ctx).toJsonResult(),
        'core' => parseCore(payload, _ctx).toJsonResult(),
        'fs' => parseFs(payload, _ctx).toJsonResult(),
        'identity' => parseIdentity(payload, _ctx).toJsonResult(),
        _ => throw StateError(collector),
      };
      _write('${dir.path}/$collector.golden.json', result);
    }
    final sections = _probeSections(
      File('${dir.path}/probe.sections').readAsStringSync(),
    );
    _write(
      '${dir.path}/probe.golden.json',
      parseProbe(sections, _ctx).toJsonResult(),
    );
    stdout.writeln('$platform: goldens rewritten');
  }
}

void _write(String path, Object? json) {
  File(
    path,
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(json)}\n');
}

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
  throw ArgumentError(v);
}

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
