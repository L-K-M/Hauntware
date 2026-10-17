/// The committed host fixtures (`klabautermann_host/test/fixtures`) as
/// the replays read them (03 §11.4): the engine budget harness and the
/// replay engine of the app's frame-timing test.
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart'
    show Collector, SamplerKind;

import 'fixture_replay.dart';

/// One platform's fixtures: the probe's sections and the payload of each
/// collector with a `<wire name>.txt`, by wire name.
final class HostFixture {
  const HostFixture({
    required this.platform,
    required this.probe,
    required this.payloads,
  });

  final String platform;
  final List<ReplaySection> probe;
  final Map<String, String> payloads;

  /// The fast collectors' payloads, which every loaded platform has.
  String get overview => payloads[Collector.overview.wireName]!;
  String get core => payloads[Collector.core.wireName]!;
}

/// Marks the container captures of `test/integration/capture.sh`
/// (`<platform>-docker-<shell>`).
const _containerCapture = '-docker-';

/// Every platform under [root] with a probe and the fast collectors'
/// fixtures, by name. The container captures are left out: they are shell
/// and userland variants of a few platforms, which would crowd the others
/// out of a ten-host fleet taken in name order, and spike S5 part 1
/// replayed the platform fixtures alone (docs/evidence/s5).
List<HostFixture> loadHostFixtures(String root) {
  final dirs = Directory(root).listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  File file(Directory dir, String name) => File('${dir.path}/$name');
  final fixtures = <HostFixture>[];
  for (final dir in dirs) {
    final platform = dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (platform.contains(_containerCapture)) continue;

    final probe = file(dir, 'probe.sections');
    if (!probe.existsSync()) continue;

    final payloads = {
      for (final collector in Collector.values)
        if (file(dir, '${collector.wireName}.txt') case final f
            when f.existsSync())
          collector.wireName: f.readAsStringSync(),
    };
    final fast = Collector.values.where((c) => c.sampler == SamplerKind.fast);
    if (!fast.every((c) => payloads.containsKey(c.wireName))) continue;

    fixtures.add(
      HostFixture(
        platform: platform,
        probe: parseProbeSections(probe.readAsStringSync()),
        payloads: payloads,
      ),
    );
  }
  if (fixtures.isEmpty) throw StateError('no host fixtures under $root');
  return fixtures;
}

/// The `journalctl -o json` rows of every platform's `journal.txt` under
/// [root], in name order.
List<String> loadJournalRows(String root) {
  final files =
      Directory(root)
          .listSync()
          .whereType<Directory>()
          .map((dir) => File('${dir.path}/journal.txt'))
          .where((file) => file.existsSync())
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final rows = [
    for (final file in files)
      ...file.readAsLinesSync().where((line) => line.trim().isNotEmpty),
  ];
  if (rows.isEmpty) throw StateError('no journal.txt rows under $root');
  return rows;
}
