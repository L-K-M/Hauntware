import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/deep_links.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/deep_link_dialogs.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show LinkReview, LinkReviewDecision, LinkReviewSnapshot;

const _captureDirectory = '../../tasks/deep-links/captures';

Future<ByteData> _fontBytes(String path) async =>
    ByteData.sublistView(File(path).readAsBytesSync());

Future<void> _loadCaptureFonts() async {
  final fontDirectory =
      Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      '${Platform.environment['HOME']}/.local/share/fonts';
  final sans = File('$fontDirectory/DejaVuSans.ttf');
  if (sans.existsSync()) {
    await (FontLoader('DejaVu Sans')..addFont(_fontBytes(sans.path))).load();
  }
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT']}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(_fontBytes(icons.path))).load();
  }
}

void main() {
  testWidgets('renders safe endpoint warnings and bounded overflow', (
    tester,
  ) async {
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await tester.runAsync(_loadCaptureFonts);
    }
    tester.view.physicalSize = const Size(1100, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final review = _TestDeepLinkReview(
      LinkReviewSnapshot<HostDeepLink>(
        current: const HostDeepLink(
          host: 'paypa\u043b\u202E.example',
          port: 2200,
          username: 'ops\u2066',
          remotePath: '/srv/reports',
          activationCount: 2,
        ),
        visibleWaiting: const [
          HostDeepLink(
            host: 'two.example',
            port: 22,
            username: 'two',
            remotePath: '/',
          ),
          HostDeepLink(
            host: 'three.example',
            port: 22,
            username: 'three',
            remotePath: '/',
          ),
        ],
        overflow: const [
          HostDeepLink(
            host: 'four.example',
            port: 22,
            username: 'four',
            remotePath: '/',
          ),
          HostDeepLink(
            host: 'five.example',
            port: 22,
            username: 'five',
            remotePath: '/',
          ),
        ],
        remainingCount: 4,
      ),
    );
    addTearDown(review.dispose);
    LinkReviewDecision? decision;

    final baseTheme = buildPoltergeistTheme(Brightness.dark);
    final theme = baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme: baseTheme.primaryTextTheme.apply(
        fontFamily: 'DejaVu Sans',
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('deepLink.capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  decision = await showDeepLinkReviewDialog(context, review);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.byKey(const ValueKey('deepLink.review')), findsOneWidget);
    expect(find.text('paypa\u043b.example'), findsOneWidget);
    expect(find.textContaining('\u202E'), findsNothing);
    expect(find.text('ops'), findsOneWidget);
    expect(
      find.text('Internationalized hostname. Check every character.'),
      findsOneWidget,
    );
    expect(
      find.text('Mixed writing systems detected in this hostname.'),
      findsOneWidget,
    );
    expect(find.textContaining('were removed for display'), findsOneWidget);
    expect(find.text('two@two.example:22'), findsOneWidget);
    expect(find.text('three@three.example:22'), findsOneWidget);
    expect(find.text('four@four.example:22'), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('deepLink.discardAll')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('deepLink.overflow')));
    await tester.pumpAndSettle();
    expect(find.text('four@four.example:22'), findsOneWidget);
    expect(find.text('five@five.example:22'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('deepLink.discardAll')))
          .onPressed,
      isNotNull,
    );

    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('deepLink.capture')),
      );
      final bytes = (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          return data!.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }))!;
      final directory = Directory(_captureDirectory)
        ..createSync(recursive: true);
      final file = File('${directory.path}/host-link-review.png');
      file.writeAsBytesSync(bytes);
      // ignore: avoid_print
      print('capture: ${file.absolute.path}');
    }

    await tester.tap(find.byKey(const ValueKey('deepLink.connect')));
    await tester.pumpAndSettle();
    expect(decision, LinkReviewDecision.connect);
  });

  testWidgets('offers explicit discard when links remain', (tester) async {
    final review = _TestDeepLinkReview(
      const LinkReviewSnapshot<HostDeepLink>(
        current: HostDeepLink(
          host: 'one.example',
          port: 22,
          username: 'ops',
          remotePath: '/',
        ),
        visibleWaiting: [
          HostDeepLink(
            host: 'two.example',
            port: 22,
            username: 'ops',
            remotePath: '/',
          ),
        ],
        overflow: [],
        remainingCount: 1,
      ),
    );
    addTearDown(review.dispose);
    LinkReviewDecision? decision;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              decision = await showDeepLinkReviewDialog(context, review);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.byKey(const ValueKey('deepLink.discardAll')));
    await tester.pumpAndSettle();

    expect(decision, LinkReviewDecision.discardAllRemaining);
  });

  testWidgets('requires a deliberate pause before review actions', (
    tester,
  ) async {
    final review = _TestDeepLinkReview(_snapshot());
    addTearDown(review.dispose);

    await tester.pumpWidget(_DialogHarness(review: review));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 749));

    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('deepLink.connect')))
          .onPressed,
      isNull,
    );

    await tester.pump(const Duration(milliseconds: 1));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('deepLink.connect')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('closes a review dialog when ownership moves', (tester) async {
    final review = _TestDeepLinkReview(_snapshot());
    addTearDown(review.dispose);
    LinkReviewDecision? decision;

    await tester.pumpWidget(
      _DialogHarness(review: review, onDecision: (value) => decision = value),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(find.byKey(const ValueKey('deepLink.review')), findsOneWidget);

    review.cancel();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('deepLink.review')), findsNothing);
    expect(decision, LinkReviewDecision.cancel);
  });

  testWidgets('requires another review when hidden overflow grows', (
    tester,
  ) async {
    final review = _TestDeepLinkReview(
      LinkReviewSnapshot<HostDeepLink>(
        current: _snapshot().current,
        visibleWaiting: const [
          HostDeepLink(
            host: 'two.example',
            port: 22,
            username: 'ops',
            remotePath: '/',
          ),
          HostDeepLink(
            host: 'three.example',
            port: 22,
            username: 'ops',
            remotePath: '/',
          ),
        ],
        overflow: const [
          HostDeepLink(
            host: 'four.example',
            port: 22,
            username: 'ops',
            remotePath: '/',
          ),
        ],
        remainingCount: 3,
      ),
    );
    addTearDown(review.dispose);

    await tester.pumpWidget(_DialogHarness(review: review));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('1 additional link activation pending'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('deepLink.discardAll')))
          .onPressed,
      isNotNull,
    );

    review.publish(
      LinkReviewSnapshot(
        current: review.snapshot.current,
        visibleWaiting: review.snapshot.visibleWaiting,
        overflow: [
          ...review.snapshot.overflow,
          const HostDeepLink(
            host: 'five.example',
            port: 22,
            username: 'ops',
            remotePath: '/',
          ),
        ],
        remainingCount: 4,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ops@five.example:22'), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('deepLink.discardAll')))
          .onPressed,
      isNull,
    );

    final updatedSummary = find.text('2 additional link activations pending');
    await tester.ensureVisible(updatedSummary);
    await tester.pumpAndSettle();
    await tester.tap(updatedSummary);
    await tester.pumpAndSettle();
    expect(find.text('ops@five.example:22'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('deepLink.discardAll')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('discard scope excludes an arrival before the next frame', (
    tester,
  ) async {
    LinkReviewDecision? decision;
    final review = _TestDeepLinkReview(
      LinkReviewSnapshot<HostDeepLink>(
        current: _snapshot().current,
        visibleWaiting: const [
          HostDeepLink(
            host: 'two.example',
            port: 22,
            username: 'ops',
            remotePath: '/',
          ),
        ],
        overflow: const [],
        remainingCount: 1,
      ),
    );
    addTearDown(review.dispose);
    await tester.pumpWidget(
      _DialogHarness(review: review, onDecision: (value) => decision = value),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 800));

    review.publish(
      LinkReviewSnapshot(
        current: review.snapshot.current,
        visibleWaiting: [
          ...review.snapshot.visibleWaiting,
          const HostDeepLink(
            host: 'unseen.example',
            port: 22,
            username: 'ops',
            remotePath: '/',
          ),
        ],
        overflow: const [],
        remainingCount: 2,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('deepLink.discardAll')));
    await tester.pumpAndSettle();

    expect(decision, LinkReviewDecision.discardAllRemaining);
    expect(review.shownSnapshot!.visibleWaiting.map((link) => link.host), [
      'two.example',
    ]);
  });

  testWidgets('shows links ignored at the queue limit', (tester) async {
    final review = _TestDeepLinkReview(
      LinkReviewSnapshot<HostDeepLink>(
        current: _snapshot().current,
        visibleWaiting: const [],
        overflow: const [],
        remainingCount: 0,
        ignoredCount: 3,
      ),
    );
    addTearDown(review.dispose);

    await tester.pumpWidget(_DialogHarness(review: review));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('3 more links were ignored.'), findsOneWidget);
  });

  testWidgets('reports links ignored once the queue drains', (tester) async {
    int? reported;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              await showDeepLinkIgnoredDialog(context, 2);
              reported = 2;
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('deepLink.ignored')), findsOneWidget);
    expect(find.text('2 more links were ignored.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('deepLink.ignored.close')));
    await tester.pumpAndSettle();
    expect(reported, 2);
  });
}

LinkReviewSnapshot<HostDeepLink> _snapshot() =>
    const LinkReviewSnapshot<HostDeepLink>(
      current: HostDeepLink(
        host: 'one.example',
        port: 22,
        username: 'ops',
        remotePath: '/',
      ),
      visibleWaiting: [],
      overflow: [],
      remainingCount: 0,
    );

final class _TestDeepLinkReview implements LinkReview<HostDeepLink> {
  _TestDeepLinkReview(this._snapshot);

  final _snapshots =
      StreamController<LinkReviewSnapshot<HostDeepLink>>.broadcast();
  final _cancelled = Completer<void>();
  LinkReviewSnapshot<HostDeepLink> _snapshot;
  LinkReviewSnapshot<HostDeepLink>? shownSnapshot;

  @override
  LinkReviewSnapshot<HostDeepLink> get snapshot => _snapshot;

  @override
  Stream<LinkReviewSnapshot<HostDeepLink>> get snapshots => _snapshots.stream;

  /// What the queue does as links arrive.
  void publish(LinkReviewSnapshot<HostDeepLink> snapshot) {
    _snapshot = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  bool get isCancelled => _cancelled.isCompleted;

  @override
  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void dispose() => unawaited(_snapshots.close());

  @override
  void markShown(LinkReviewSnapshot<HostDeepLink> snapshot) {
    shownSnapshot = snapshot;
  }
}

final class _DialogHarness extends StatelessWidget {
  const _DialogHarness({required this.review, this.onDecision});

  final LinkReview<HostDeepLink> review;
  final ValueChanged<LinkReviewDecision>? onDecision;

  @override
  Widget build(BuildContext context) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => FilledButton(
        onPressed: () async {
          final decision = await showDeepLinkReviewDialog(context, review);
          onDecision?.call(decision);
        },
        child: const Text('Open'),
      ),
    ),
  );
}
