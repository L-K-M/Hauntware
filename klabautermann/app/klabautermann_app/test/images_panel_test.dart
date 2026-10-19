import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/docker/images_panel.dart';
import 'package:klabautermann_app/ui/docker/images_view.dart';
import 'package:klabautermann_app/ui/sortable_table.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
const _mib = 1024 * 1024;

const _wide = Size(1000, 600);
const _phone = Size(390, 900);

/// When the lists are read; local, so nothing depends on the test
/// machine's zone.
final _now = DateTime(2026, 10, 15, 14, 30);

/// A full image id whose short form is [short].
String _id(String short) => 'sha256:$short${'0' * (64 - short.length)}';

final _nginx = _id('3f1c9a6b2e8d');
final _postgres = _id('8b7a6c5d4e3f');
final _worker = _id('c4d5e6f7a8b9');
final _orphan = _id('d0e1f2a3b4c5');
final _old = _id('e6f7a8b9c0d1');
final _hello = _id('f2a3b4c5d6e7');

/// Six images as API 1.52 lists them, with the counts it carries: two
/// tags on one, an unused one, two dangling ones (one with no tags, one
/// with Docker's `<none>` placeholder) and one only a stopped container
/// uses (IMG-01). Pass [counted] false for API 1.44's list, which carries
/// no counts.
List<ImageSummary> _images({bool counted = true}) => [
  for (final (id, tags, size, age, count) in [
    (
      _nginx,
      ['nginx:1.27', 'nginx:latest'],
      187 * _mib,
      const Duration(days: 21),
      2,
    ),
    (_postgres, ['postgres:16'], 438 * _mib, const Duration(days: 4), 1),
    (_worker, ['myorg/worker:5'], 92 * _mib, const Duration(hours: 5), 0),
    (_orphan, <String>[], 92 * _mib, const Duration(days: 75), 0),
    (_old, ['<none>:<none>'], 1229 * _mib, const Duration(days: 1100), 0),
    (_hello, ['hello-world:latest'], 13 * 1024, const Duration(days: 800), 1),
  ])
    dockerImage(
      id,
      tags: tags,
      size: size,
      created: _now.subtract(age),
      containers: counted ? count : null,
    ),
];

/// The containers the counts above describe: two of nginx, one naming its
/// image without the `sha256:` prefix, one of postgres and a hello-world
/// that never started.
final _containers = [
  dockerContainer('a1', name: 'web-1', imageId: _nginx),
  dockerContainer('a2', name: 'web-2', imageId: _nginx.substring(7)),
  dockerContainer('b1', name: 'db', image: 'postgres:16', imageId: _postgres),
  dockerContainer(
    'c1',
    name: 'hello',
    image: 'hello-world',
    state: 'created',
    status: 'Created',
    imageId: _hello,
  ),
];

/// The images' names by id, so orders read as names.
final _names = {
  _nginx: 'nginx',
  _postgres: 'postgres',
  _worker: 'worker',
  _orphan: 'orphan',
  _old: 'old',
  _hello: 'hello',
};

final class _Panel {
  _Panel(this.engine, this.visible);

  final FakeEngineClient engine;
  final ValueNotifier<bool> visible;

  List<DockerWatch> get watches => engine.sentOfType<DockerWatch>().cast();
  List<DockerUnwatch> get unwatches =>
      engine.sentOfType<DockerUnwatch>().cast();

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  /// Delivers [images] and, unless null, [containers].
  Future<void> list(
    WidgetTester tester, {
    List<ImageSummary>? images,
    List<ContainerSummary>? containers,
  }) async {
    await emit(
      tester,
      dockerImageList(_serverId, images ?? _images(), at: _now),
    );
    if (containers != null) {
      await emit(tester, dockerContainerList(_serverId, containers, at: _now));
    }
  }
}

Future<_Panel> _pump(
  WidgetTester tester, {
  Size size = _wide,
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.linux,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine, now: () => _now);
  final visible = ValueNotifier(true);
  addTearDown(() async {
    monitoring.dispose();
    visible.dispose();
    await engine.close();
  });

  final base = brightness == Brightness.light
      ? GhostTheme.light(klabautermannThemeStyle, platform: platform)
      : GhostTheme.dark(klabautermannThemeStyle, platform: platform);
  final theme = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: goldenFontFamily),
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: RepaintBoundary(
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: ValueListenableBuilder(
                valueListenable: visible,
                builder: (context, shows, _) => ImagesPanel(
                  monitoring: monitoring,
                  serverId: _serverId,
                  visible: shows,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Panel(engine, visible);
}

const _prefix = 'images.row.';

/// The images the panel shows, top to bottom, by name.
List<String> _order(WidgetTester tester) {
  final rows = [
    for (final element in find.byType(Semantics).evaluate())
      if (element.widget.key case ValueKey<String>(
        :final value,
      ) when value.startsWith(_prefix))
        (
          key: value.substring(_prefix.length),
          top: tester.getTopLeft(find.byWidget(element.widget)).dy,
        ),
  ]..sort((a, b) => a.top.compareTo(b.top));
  return [for (final row in rows) _names[row.key] ?? row.key];
}

Finder _header(ImageColumn column) =>
    find.byKey(ValueKey('images.column.${column.name}'));

/// The semantics label of [name]'s row.
Finder _row(String id) => find.byKey(ValueKey('$_prefix$id'));

String _label(WidgetTester tester, String id) =>
    tester.getSemantics(_row(id)).label;

Future<void> _choose(WidgetTester tester, String filter) async {
  await tester.tap(find.widgetWithText(ChoiceChip, filter));
  await tester.pumpAndSettle();
}

/// 03 §10.4's Images sub-tab (IMG-01) over the image watch.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  testWidgets('watches the images and containers while it shows and reads '
      'nothing hidden', (tester) async {
    final panel = await _pump(tester);
    expect(panel.watches, hasLength(1));
    expect(panel.watches.single.lists, {
      DockerWatchList.images,
      DockerWatchList.containers,
    });
    expect(panel.watches.single.statsFor, isEmpty);
    expect(find.text('Reading the images…'), findsOneWidget);

    panel.visible.value = false;
    await tester.pumpAndSettle();
    expect(panel.unwatches.single.watchId, panel.watches.single.watchId);

    panel.visible.value = true;
    await tester.pumpAndSettle();
    expect(panel.watches, hasLength(2));
    expect(panel.watches.last.watchId, isNot(panel.watches.first.watchId));
  });

  testWidgets('shows each column: tags, short ID, IEC size, age and date, '
      'use, and the dangling badge', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, containers: _containers);

    for (final text in [
      'nginx:1.27, nginx:latest',
      '3f1c9a6b2e8d',
      // IEC units (A11Y-06).
      '187 MiB',
      '1.2 GiB',
      '13 KiB',
      '3 weeks ago',
      'Sep 24, 2026',
      '5 hours ago',
      '4 days ago',
      '2 months ago',
      '2 years ago',
      '3 years ago',
      'In use (2)',
      'In use (1)',
    ]) {
      expect(find.text(text), findsWidgets, reason: text);
    }
    // Both dangling images, with and without the `<none>` placeholder;
    // the filter chips name Unused and Dangling once more.
    expect(find.byType(ImageDanglingBadge), findsNWidgets(2));
    expect(find.text('<none>:<none>'), findsNothing);
    expect(find.text('Unused'), findsNWidgets(4));

    // Each row reads as its cells (A11Y-03).
    expect(
      _label(tester, _nginx),
      'Tags: nginx:1.27, nginx:latest\n'
      'ID: 3f1c9a6b2e8d\n'
      'Size: 187 MiB\n'
      'Created: 3 weeks ago, Sep 24, 2026\n'
      'Use: In use by 2 containers',
    );
    expect(_label(tester, _orphan), startsWith('Tags: Dangling\n'));
    expect(_label(tester, _orphan), endsWith('Use: Unused'));
    expect(
      _label(tester, _hello),
      endsWith('Use: In use by 1 container'),
      reason: 'a container that never started still uses its image',
    );
  });

  testWidgets('sorts by tags, size, age and use', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, containers: _containers);

    // By tag; dangling images have none and sort last.
    expect(_order(tester), [
      'hello',
      'worker',
      'nginx',
      'postgres',
      'orphan',
      'old',
    ]);

    // The biggest first; equal sizes keep the engine's order.
    await tester.tap(_header(ImageColumn.size));
    await tester.pumpAndSettle();
    expect(_order(tester), [
      'old',
      'postgres',
      'nginx',
      'worker',
      'orphan',
      'hello',
    ]);

    // The newest first.
    await tester.tap(_header(ImageColumn.created));
    await tester.pumpAndSettle();
    expect(_order(tester), [
      'worker',
      'postgres',
      'nginx',
      'orphan',
      'hello',
      'old',
    ]);

    // The unused first.
    await tester.tap(_header(ImageColumn.use));
    await tester.pumpAndSettle();
    expect(_order(tester), [
      'worker',
      'orphan',
      'old',
      'postgres',
      'hello',
      'nginx',
    ]);

    await tester.tap(_header(ImageColumn.id));
    await tester.pumpAndSettle();
    expect(_order(tester).first, 'nginx');
  });

  testWidgets('filters the unused and the dangling, and searches by tag or '
      'ID', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, containers: _containers);

    await _choose(tester, 'Unused');
    expect(_order(tester), ['worker', 'orphan', 'old']);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Unused'))
          .selected,
      isTrue,
    );

    await _choose(tester, 'Dangling');
    expect(_order(tester), ['orphan', 'old']);

    await _choose(tester, 'All');
    await tester.enterText(find.byType(TextField), 'NGINX');
    await tester.pumpAndSettle();
    expect(_order(tester), ['nginx']);

    // An ID, short or in full.
    await tester.enterText(find.byType(TextField), 'c4d5e6');
    await tester.pumpAndSettle();
    expect(_order(tester), ['worker']);

    // The search and a filter together.
    await tester.enterText(find.byType(TextField), 'postgres');
    await tester.pumpAndSettle();
    await _choose(tester, 'Unused');
    expect(_order(tester), isEmpty);
    expect(find.text('No image matches the search.'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(_order(tester), hasLength(3));

    // A filter that hides every image says so.
    await panel.list(
      tester,
      images: [
        for (final image in _images())
          if (!image.isDangling) image,
      ],
    );
    await _choose(tester, 'Dangling');
    expect(find.text('No image is dangling.'), findsOneWidget);
    await panel.list(
      tester,
      containers: [
        ..._containers,
        dockerContainer('d1', imageId: _worker),
      ],
      images: _images().sublist(0, 3),
    );
    await _choose(tester, 'Unused');
    expect(find.text('Every image is in use by a container.'), findsOneWidget);
  });

  testWidgets('below API 1.51 tells the images in use from the container '
      'list', (tester) async {
    final panel = await _pump(tester);
    await panel.emit(
      tester,
      dockerReady(_serverId, api: const ApiVersion(1, 44)),
    );
    await panel.list(tester, images: _images(counted: false));

    // No count, and no container list yet.
    expect(_label(tester, _nginx), endsWith('Use: unknown'));
    await _choose(tester, 'Unused');
    expect(_order(tester), isEmpty, reason: 'unknown is not unused');
    await _choose(tester, 'All');

    await panel.emit(
      tester,
      dockerContainerList(_serverId, _containers, at: _now),
    );
    expect(_label(tester, _nginx), endsWith('Use: In use by 2 containers'));
    expect(_label(tester, _postgres), endsWith('Use: In use by 1 container'));
    expect(_label(tester, _worker), endsWith('Use: Unused'));

    // A container created from the worker image counts at once: the
    // engine re-lists the containers, not the images.
    await panel.emit(
      tester,
      dockerContainerList(_serverId, [
        ..._containers,
        dockerContainer('d1', name: 'worker', imageId: _worker),
      ], at: _now),
    );
    expect(_label(tester, _worker), endsWith('Use: In use by 1 container'));
  });

  testWidgets('below API 1.51, a failed container list leaves the use '
      'unknown and says why', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, images: _images(counted: false));
    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.containers,
        DockerQueryFailure.connectionFailed,
        at: _now,
        detail: 'read: connection reset by peer',
      ),
    );
    expect(
      find.text(
        'Which images are in use is unknown: this engine\'s API reports no '
        'count, and the containers could not be listed.',
      ),
      findsOneWidget,
    );
    expect(find.text('read: connection reset by peer'), findsOneWidget);
    expect(find.text('unknown'), findsNWidgets(_images().length));

    // From 1.51 the counts stand in.
    await panel.list(tester);
    expect(find.textContaining('Which images are in use'), findsNothing);
    expect(_label(tester, _nginx), endsWith('Use: In use by 2 containers'));
  });

  testWidgets('from API 1.51 the image counts stand in only until the '
      'containers are listed, which follow a container created or removed', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.list(tester);
    expect(_label(tester, _nginx), endsWith('Use: In use by 2 containers'));
    expect(_label(tester, _hello), endsWith('Use: In use by 1 container'));

    // The hello-world container was removed and one created from the
    // worker image since the images were listed.
    await panel.emit(
      tester,
      dockerContainerList(_serverId, [
        ..._containers.sublist(0, 3),
        dockerContainer('d1', name: 'worker', imageId: _worker),
      ], at: _now),
    );
    expect(_label(tester, _hello), endsWith('Use: Unused'));
    expect(_label(tester, _worker), endsWith('Use: In use by 1 container'));
    expect(_label(tester, _nginx), endsWith('Use: In use by 2 containers'));
  });

  testWidgets('says why the list failed, keeps the last one and watches '
      'anew on retry', (tester) async {
    final panel = await _pump(tester);
    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.images,
        DockerQueryFailure.daemonError,
        at: _now,
        detail: 'Error response from daemon: client version too old',
      ),
    );
    expect(
      find.text('The engine refused or failed to list the images.'),
      findsOneWidget,
    );
    expect(
      find.text('Error response from daemon: client version too old'),
      findsOneWidget,
    );
    expect(find.text('Reading the images…'), findsNothing);

    final before = panel.watches.last.watchId;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(panel.unwatches.single.watchId, before);
    expect(panel.watches.last.watchId, isNot(before));

    await panel.list(tester, containers: _containers);
    expect(find.text('Try again'), findsNothing);
    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.images,
        DockerQueryFailure.connectionFailed,
        at: _now,
      ),
    );
    expect(
      find.text(
        'The connection to the engine failed while listing the images.',
      ),
      findsOneWidget,
    );
    expect(find.text('The list below is the last one read.'), findsOneWidget);
    expect(_order(tester), hasLength(6));
  });

  testWidgets('a refused watch and an empty engine say so', (tester) async {
    final panel = await _pump(tester);
    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.images,
        DockerQueryFailure.tooManyQueries,
        at: _now,
      ),
    );
    expect(
      find.text(
        'This server already has as many Docker watches open as Klabautermann '
        'allows.',
      ),
      findsOneWidget,
    );

    await panel.list(tester, images: const []);
    expect(find.text('This engine has no images.'), findsOneWidget);
  });

  testWidgets('names low-session mode on a relay, where the list polls', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.list(tester);
    await panel.emit(tester, dockerReady(_serverId, lowSession: true));
    expect(
      find.textContaining('Low-session mode'),
      findsNothing,
      reason: 'the socket forward follows events at no session cost',
    );

    await panel.emit(
      tester,
      dockerReady(_serverId, rank: DockerRank.cliRelay, lowSession: true),
    );
    expect(
      find.text(
        'Low-session mode: the list is read again every 15 seconds instead '
        'of following engine events.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a phone lists two-line rows with a sort menu', (tester) async {
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.list(tester, containers: _containers);
    expect(find.byType(SortableTable<ImageEntry>), findsNothing);
    expect(find.text('Sort by'), findsOneWidget);
    expect(find.text('nginx:1.27, nginx:latest'), findsOneWidget);
    expect(find.text('Size: 187 MiB'), findsOneWidget);
    expect(find.text('Created: 3 weeks ago, Sep 24, 2026'), findsOneWidget);
    expect(find.text('Use: In use by 2 containers'), findsOneWidget);
    expect(find.byType(ImageDanglingBadge), findsNWidgets(2));
    expect(_order(tester).take(2), ['hello', 'worker']);
    expect(
      _label(tester, _orphan),
      startsWith('Tags: Dangling\nID: d0e1f2a3b4c5\n'),
    );

    // The biggest first.
    await tester.tap(find.text('Tags').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Size').last);
    await tester.pumpAndSettle();
    expect(_order(tester).take(2), ['old', 'postgres']);

    await tester.tap(find.byTooltip('Sorted descending'));
    await tester.pumpAndSettle();
    expect(_order(tester).first, 'hello');
    expect(tester.takeException(), isNull);
  });

  testWidgets('at twice the text size a desktop panel takes the two-line '
      'rows rather than a squeezed table', (tester) async {
    final panel = await _pump(tester, textScale: 2);
    await panel.list(tester, containers: _containers);
    expect(find.byType(SortableTable<ImageEntry>), findsNothing);
    expect(find.text('Size: 187 MiB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('ages grade as docker images grades them', () {
    for (final (age, expected) in [
      (const Duration(seconds: -5), (ImageAgeUnit.lessThanMinute, 0)),
      (const Duration(seconds: 59), (ImageAgeUnit.lessThanMinute, 0)),
      (const Duration(minutes: 1), (ImageAgeUnit.minutes, 1)),
      (const Duration(minutes: 59), (ImageAgeUnit.minutes, 59)),
      (const Duration(hours: 47), (ImageAgeUnit.hours, 47)),
      (const Duration(hours: 47, minutes: 29), (ImageAgeUnit.hours, 47)),
      (const Duration(hours: 47, minutes: 30), (ImageAgeUnit.days, 2)),
      (const Duration(hours: 48), (ImageAgeUnit.days, 2)),
      (const Duration(days: 13), (ImageAgeUnit.days, 13)),
      (
        const Duration(days: 13, hours: 23, minutes: 30),
        (ImageAgeUnit.weeks, 2),
      ),
      (const Duration(days: 14), (ImageAgeUnit.weeks, 2)),
      (const Duration(days: 59), (ImageAgeUnit.weeks, 8)),
      (const Duration(days: 60), (ImageAgeUnit.months, 2)),
      (const Duration(days: 729), (ImageAgeUnit.months, 24)),
      (const Duration(days: 730), (ImageAgeUnit.years, 2)),
    ]) {
      expect(imageAge(age), expected, reason: '$age');
    }
  });

  test('a count the daemon did not compute is unknown, and the container '
      'list matches ids with or without their prefix', () {
    expect(
      imageContainerCount(dockerImage('sha256:aa', containers: -1), null),
      isNull,
    );
    expect(
      imageContainerCount(dockerImage('sha256:aa', containers: 3), null),
      3,
    );
    final byImage = containersByImage([
      dockerContainer('c-1', imageId: 'sha256:aa'),
      dockerContainer('c-2', imageId: 'aa'),
      dockerContainer('c-3'),
    ]);
    expect(byImage, {'aa': 2});
    expect(imageContainerCount(dockerImage('aa', containers: 0), byImage), 2);
    expect(
      imageContainerCount(dockerImage('sha256:bb', containers: 4), byImage),
      0,
      reason: 'the container list wins over a count that lags it',
    );
  });

  group('golden', () {
    // 03 §11.1: tagged, unused, dangling and in-use images, sizes from
    // KiB to GiB and ages from hours to years, on desktop.
    for (final brightness in Brightness.values) {
      testWidgets('desktop, ${brightness.name}', (tester) async {
        final panel = await _pump(tester, brightness: brightness);
        await panel.list(tester, containers: _containers);
        await expectLater(
          find.byType(ImagesPanel),
          matchesGoldenFile(
            'goldens/images_panel_desktop_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
