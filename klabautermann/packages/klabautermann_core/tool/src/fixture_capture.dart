/// Fixture capture: the real program once per collector, redacted and
/// reviewed into `klabautermann_host/test/fixtures/<platform-id>/`
/// (03 §6.5).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart';

import 'local_sampler.dart';
import 'redaction.dart';

/// The collectors with a `<collector>.txt` fixture: every tick
/// collector but the probe, which is stored apart, in `probe.sections`.
final kFixtureCollectors = [
  for (final c in Collector.values)
    if (c != Collector.probe && c.argValidators.isEmpty) c,
];

/// A capture could not produce or write its fixture.
final class CaptureFailure implements Exception {
  const CaptureFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The sections of one capture, as the frame parser delivered them.
final class Capture {
  const Capture(this.launch, this.sections, this.probe);

  final SamplerLaunch launch;
  final Map<Collector, HwsSection> sections;
  final List<HwsSection> probe;

  /// The probe decoded, for the platform id and the redaction literals.
  HostProfile get profile => parseProbe(
    probe.map(ProbeSection.fromEvent).whereType<ProbeSection>().toList(),
    ParseContext.standard,
  ).value;

  /// The host's names as hostnamectl reports them in `identity`: the
  /// static name can differ from the kernel's transient one.
  List<String> get hostNames {
    final identity = parseIdentity(
      utf8.decode(sections[Collector.identity]!.payload, allowMalformed: true),
      ParseContext.standard,
    ).value.hostnamectl;
    return [
      for (final key in const ['Hostname', 'StaticHostname'])
        if (identity[key] case final String name when name.isNotEmpty) name,
    ];
  }
}

/// Bounds READY and each reply; the program's own guards end a slow
/// collector after 10 s per command where `timeout` exists.
const _replyTimeout = Duration(minutes: 5);

/// Runs the slow program (the probe, then each slow collector) and the
/// fast program (each fast collector), one request per collector.
Future<Capture> captureLocal(
  SamplerLaunch launch,
  Map<String, String> environment,
) async {
  final sections = <Collector, HwsSection>{};
  var probe = <HwsSection>[];
  for (final kind in SamplerKind.values) {
    final sampler = await LocalSampler.start(
      launch,
      kind: kind,
      environment: environment,
    );
    try {
      await sampler.ready.timeout(_replyTimeout);
      final collectors = [
        if (kind == SamplerKind.slow) Collector.probe,
        ...kFixtureCollectors.where((c) => c.sampler == kind),
      ];
      var seq = 0;
      for (final c in collectors) {
        final reply = await sampler.request(++seq, [c]).timeout(_replyTimeout);
        final tick = reply.tick;
        if (tick == null) {
          throw CaptureFailure('${c.wireName} reply lost: ${reply.lostDetail}');
        }
        if (c == Collector.probe) {
          probe = tick.sections.toList();
          continue;
        }
        sections[c] =
            tick.section(c.wireName) ??
            (throw CaptureFailure('${c.wireName} reply has no section'));
      }
    } finally {
      await sampler.close();
    }
  }
  return Capture(launch, sections, probe);
}

final _platformId = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

/// Whether [id] can name a fixture directory.
bool isPlatformId(String id) => _platformId.hasMatch(id);

/// The fixture directory name from the probe's os-release: `<ID>-` and
/// the first two VERSION_ID components without the dot, or the first
/// alone for the RHEL family, whose minor versions are updates of one
/// release (`ubuntu-2404`, `debian-12`, `rhel-8`, `alpine-322`). Null
/// when either field is missing or the name is not [isPlatformId].
String? platformIdFor(HostProfile profile) {
  final id = profile.distroId?.toLowerCase();
  final version = profile.distroVersionId;
  if (id == null || version == null) return null;
  final rhel = id == 'rhel' || ' ${profile.distroIdLike} '.contains(' rhel ');
  final parts = version.split('.').take(rhel ? 1 : 2);
  final platform = '$id-${parts.join()}';
  return isPlatformId(platform) ? platform : null;
}

/// useradd's UID_MIN and UID_MAX defaults (login.defs(5)) on Debian,
/// Ubuntu, Fedora, RHEL and Arch: accounts in this range are people's.
const _personalUids = (min: 1000, max: 60000);

/// The kernel's overflow uid, `nobody`'s.
const _nobodyUid = 65534;

/// The literals a local capture redacts: [hostNames] with each FQDN's
/// first label, the name and home directory of the capturing user (home
/// [home], unless `/` or `/root`) unless their uid is a system one, and
/// those of every personal account in [passwd]. Names a
/// fixture keeps are left out: `localhost` and the os-release ID and
/// ID_LIKE words, which cloud images use as host and default user names
/// and which the `identity` and probe payloads must keep.
RedactionLiterals captureLiterals(
  HostProfile profile, {
  required List<String> hostNames,
  required String home,
  required String passwd,
  List<String> extra = const [],
}) {
  final generic = {
    'localhost',
    ?profile.distroId?.toLowerCase(),
    ...?profile.distroIdLike?.toLowerCase().split(' '),
  };
  bool keep(String name) =>
      name.isNotEmpty && !generic.contains(name.toLowerCase());
  bool personal(int? uid) =>
      uid != null && uid >= _personalUids.min && uid <= _personalUids.max;

  final hosts = <String>{
    for (final h in hostNames) ...[h, h.split('.').first],
  }.where(keep);
  // Directory-service (sssd, FreeIPA) and systemd-homed accounts lie
  // above UID_MAX, so the capturing user need only be no system account;
  // an unknown uid fails safe.
  final uid = profile.uid;
  final capturer =
      uid == null || (uid >= _personalUids.min && uid != _nobodyUid);
  // User name to home directory; the capturing user comes first.
  final accounts = <String, String>{
    if (profile.user case final user? when capturer) user: home,
  };
  // name:password:uid:gid:gecos:home:shell (passwd(5)).
  for (final fields in LineSplitter.split(passwd).map((l) => l.split(':'))) {
    if (fields.length < 7 || !personal(int.tryParse(fields[2]))) continue;
    accounts.putIfAbsent(fields[0], () => fields[5]);
  }
  accounts.removeWhere((user, _) => !keep(user));
  return RedactionLiterals(
    hostNames: hosts.toList(),
    userNames: accounts.keys.toList(),
    homeDirs: accounts.values
        .where((h) => h != '/' && h != '/root')
        .toSet()
        .toList(),
    extra: extra,
  );
}

/// A line of a rendered file that the review blocks.
final class Residue {
  const Residue(this.file, this.line, this.reason, this.text);

  final String file;
  final int line;
  final String reason;

  /// The line itself, as Latin-1 text.
  final String text;

  @override
  String toString() => '$file:$line: $reason';
}

/// The fixture files of a capture and what the redaction and review
/// found. Write [files] only when [residue] is empty.
final class FixtureFiles {
  const FixtureFiles(this.files, this.counts, this.residue);

  /// File name to content.
  final Map<String, List<int>> files;

  /// Replacements per rule, over the payloads.
  final Map<String, int> counts;

  /// What the review found, file by file.
  final List<Residue> residue;
}

/// Redacts [capture], renders its fixture files and reviews them:
/// `<collector>.txt` (the payload and a final newline), `probe.sections`
/// (the `### <area> <status>` format) and `SOURCE.md` (provenance, the
/// section statuses the `.txt` files do not hold, the redaction).
FixtureFiles renderFixtureFiles(
  Capture capture,
  Redactor redactor, {
  required DateTime capturedAt,
}) {
  final files = <String, List<int>>{};
  final counts = <String, int>{};
  List<int> redact(String collector, List<int> payload) {
    final r = redactor.redact(collector, payload);
    r.counts.forEach((rule, n) => counts[rule] = (counts[rule] ?? 0) + n);
    return r.bytes;
  }

  for (final c in kFixtureCollectors) {
    final s = capture.sections[c]!;
    files['${c.wireName}.txt'] = [...redact(c.wireName, s.payload), 0x0a];
  }

  final probe = BytesBuilder();
  for (final event in capture.probe) {
    final s = ProbeSection.fromEvent(event);
    if (s == null) continue;
    final payload = redact(event.collector, utf8.encode(s.payload));
    if (latin1.decode(payload).split('\n').any((l) => l.startsWith('### '))) {
      throw CaptureFailure('probe area ${s.name} has a "### " line');
    }
    probe
      ..add(latin1.encode('### ${s.name} ${s.status.name}\n'))
      ..add(payload)
      ..addByte(0x0a);
  }
  files['probe.sections'] = probe.toBytes();

  final summary = counts.isEmpty
      ? 'nothing replaced'
      : (counts.entries.map((e) => '${e.key} ${e.value}').toList()..sort())
            .join(', ');
  // Redacted too: the launch label can hold a home directory.
  files['SOURCE.md'] = redactor
      .redact('SOURCE.md', utf8.encode(_sourceMd(capture, capturedAt, summary)))
      .bytes;

  final residue = <Residue>[];
  files.forEach((name, bytes) {
    final text = latin1.decode(bytes);
    final lines = text.split('\n');
    for (final (line, reason) in redactor.review(text)) {
      residue.add(Residue(name, line, reason, lines[line - 1]));
    }
  });
  return FixtureFiles(files, counts, residue);
}

String _sourceMd(Capture capture, DateTime capturedAt, String summary) {
  final p = capture.profile;
  final distro = p.distroPrettyName ?? 'an unknown distribution';
  final kernel = [p.kernelSys, p.kernelRelease, p.kernelArch].nonNulls;
  final system = kernel.isEmpty
      ? '$distro, an unknown kernel'
      : '$distro, ${kernel.join(' ')}';
  final date = capturedAt.toUtc().toIso8601String().substring(0, 10);
  final rows = [
    for (final c in kFixtureCollectors)
      '| `${c.wireName}` | ${capture.sections[c]!.status.name} |',
  ];
  final areas = [
    for (final s in capture.probe)
      '${s.collector.replaceFirst(kProbeSectionPrefix, '')} ${s.status.name}',
  ];
  return '''
Captured on $date by `klabautermann_core/tool/capture_fixtures.dart`
(local mode, `${capture.launch.label}`) from
$system;
collector-set version $kCollectorSetVersion. Goldens come from
`klabautermann_host/tool/regen_goldens.dart`.

Section statuses (each `.txt` file holds the payload only):

| Collector | Status |
|---|---|
${rows.join('\n')}

Probe areas: ${areas.join(', ')}.

Redaction (03 §6.5): $summary. Every `procs` argument after argv[0], and
the part of argv[0] after its first space, reads `$kRedacted`. The
review found nothing left.
''';
}

/// Writes [fixture]'s files into [dir], or nothing while its review
/// found residue. An existing [dir] is refused unless [replace] is set;
/// then it is emptied first, so that every file in it comes from this
/// capture. Returns the non-golden files that removed and this capture
/// did not write again.
List<String> writeFixtureDir(
  Directory dir,
  FixtureFiles fixture, {
  required bool replace,
}) {
  if (fixture.residue.isNotEmpty) {
    throw CaptureFailure(
      'the review found ${fixture.residue.length} line(s) to fix; '
      'nothing was written',
    );
  }
  final files = fixture.files;
  final removed = <String>[];
  if (dir.existsSync()) {
    if (!replace) {
      throw CaptureFailure('${dir.path} exists; pass --replace to empty it');
    }
    for (final entry in dir.listSync()) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (!files.containsKey(name) && !name.endsWith('.golden.json')) {
        removed.add(name);
      }
    }
    dir.deleteSync(recursive: true);
  }
  dir.createSync(recursive: true);
  files.forEach((name, bytes) {
    File('${dir.path}/$name').writeAsBytesSync(bytes);
  });
  return removed..sort();
}
