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
      final payload = File('${dir.path}/$collector.txt').readAsStringSync();
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
      _write('${dir.path}/$collector.golden.json', result);
    }
    final sections = _probeSections(
      File('${dir.path}/probe.sections').readAsStringSync(),
    );
    _write(
      '${dir.path}/probe.golden.json',
      parseProbe(sections, _ctx).toJsonResult(),
    );
    for (final read in _optionalReads) {
      final file = File('${dir.path}/$read.txt');
      if (!file.existsSync()) continue;
      _write(
        '${dir.path}/$read.golden.json',
        _optionalJson(read, file.readAsStringSync()),
      );
    }
    _write('${dir.path}/jobs.golden.json', _jobsJson(dir.path));
    stdout.writeln('$platform: goldens rewritten');
  }
}

/// Mirrors `_optionalReads` in `test/fixtures_test.dart`.
const _optionalReads = ['timer_detail', 'oncalendar', 'journal', 'dmesg'];

Map<String, Object?> _optionalJson(String read, String payload) =>
    switch (read) {
      'timer_detail' => parseTimerDetail(payload, _ctx).toJsonResult(),
      'oncalendar' => parseOnCalendar(payload).toJsonResult(),
      'journal' => parseJournalLines(payload).toJsonResult(),
      'dmesg' => parseDmesgJson(payload).toJsonResult(),
      _ => throw StateError(read),
    };

/// Mirrors `_jobsJson` in `test/fixtures_test.dart`.
Map<String, Object?> _jobsJson(String dir) {
  final now = DateTime.utc(2026, 10, 14, 12);
  final profile = parseProbe(
    _probeSections(File('$dir/probe.sections').readAsStringSync()),
    _ctx,
  ).value;
  final offset = RegExp(
    r'^([+-])(\d\d)(\d\d)$',
  ).firstMatch(profile.zoneOffset ?? '');
  final minutes = offset == null
      ? 0
      : (int.parse(offset[2]!) * 60 + int.parse(offset[3]!)) *
            (offset[1] == '-' ? -1 : 1);
  final jobs = mergeJobs(
    cron: parseCron(File('$dir/cron.txt').readAsStringSync(), _ctx).value,
    timers: parseTimers(File('$dir/timers.txt').readAsStringSync(), _ctx).value,
    nowUtc: now,
    zone: ServerZone(
      offset: Duration(minutes: minutes),
      ianaName: profile.timezone,
    ),
    runCount: 2,
  );
  final detailFile = File('$dir/timer_detail.txt');
  final detail = detailFile.existsSync()
      ? parseTimerDetail(detailFile.readAsStringSync(), _ctx).value
      : null;
  if (detail != null) {
    final read = parseOnCalendar(
      File('$dir/oncalendar.txt').readAsStringSync(),
    ).value;
    final first = jobs.indexWhere((j) => j is TimerJobEntry);
    jobs[first] = (jobs[first] as TimerJobEntry).withDetail(
      detail,
      // oncalendar.txt is the read issued for the timer's one calendar
      // expression. Reads are keyed by the expression sent, as the
      // output names it only when it differs from the normalized form.
      calendars: {detail.calendar.single: read},
    );
  }
  return {
    'nowUtc': now.toIso8601String(),
    'zoneOffsetMinutes': minutes,
    'zoneName': profile.timezone,
    'jobs': jobs.map((j) => j.toJson()).toList(),
    if (detail != null)
      'timerCalendarReads': timerCalendarCommands(
        detail,
        runCount: 2,
        systemdMajor: profile.systemdVersion,
      ),
  };
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
  if (v is ProcsSnapshot) return v.toJson();
  if (v is UnitsSnapshot) return v.toJson();
  if (v is TimersSnapshot) return v.toJson();
  if (v is CronSnapshot) return v.toJson();
  if (v is TimerDetail) return v.toJson();
  if (v is OnCalendarResult) return v.toJson();
  if (v is JournalEntry) return v.toJson();
  if (v is DmesgRecord) return v.toJson();
  if (v is List) return v.map(_toJson).toList();
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
