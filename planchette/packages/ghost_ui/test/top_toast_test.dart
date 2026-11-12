import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

void main() {
  testWidgets('top toast shows its message then auto-dismisses', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showTopToast(
                Overlay.of(context),
                message: 'Inserted: ls -la',
                duration: const Duration(seconds: 3),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump(); // insert the overlay entry
    await tester.pump(const Duration(milliseconds: 200)); // fade/slide in
    expect(find.text('Inserted: ls -la'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4)); // past the duration
    await tester.pumpAndSettle(); // fade out and process removal
    expect(find.text('Inserted: ls -la'), findsNothing);
  });

  testWidgets('toasts stack instead of overlapping, and actions fire', (
    tester,
  ) async {
    var uploaded = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showTopToast(
                  Overlay.of(context),
                  message: 'first',
                  duration: const Duration(seconds: 6),
                );
                showTopToast(
                  Overlay.of(context),
                  message: 'second',
                  duration: const Duration(seconds: 6),
                  actionLabel: 'Upload',
                  onAction: () => uploaded++,
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    // Stacked vertically, not painted on top of each other.
    final firstBottom = tester.getBottomLeft(find.text('first')).dy;
    final secondTop = tester.getTopLeft(find.text('second')).dy;
    expect(secondTop, greaterThan(firstBottom));

    await tester.tap(find.text('Upload'));
    await tester.pump();
    expect(uploaded, 1); // The action fires immediately, before the fade.
    // A second tap during the fade-out must not re-fire the action.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Upload'), warnIfMissed: false);
    await tester.pump();
    expect(uploaded, 1);
    await tester.pumpAndSettle(); // fade out
    expect(find.text('second'), findsNothing);
    expect(find.text('first'), findsOneWidget);

    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
  });

  testWidgets('caps visible notices and exposes callback-free overflow', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    late OverlayState overlay;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            overlay = Overlay.of(context);
            return const Scaffold();
          },
        ),
      ),
    );

    for (var i = 1; i <= 5; i++) {
      showTopToast(
        overlay,
        message: 'notice $i',
        duration: const Duration(minutes: 1),
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('notice 1'), findsOneWidget);
    expect(find.text('notice 2'), findsOneWidget);
    expect(find.text('notice 3'), findsOneWidget);
    expect(find.text('notice 4'), findsNothing);
    expect(find.text('notice 5'), findsNothing);
    expect(find.text('+2'), findsOneWidget);
    final moreLabel = MaterialLocalizations.of(
      tester.element(find.text('+2')),
    ).moreButtonTooltip;
    expect(find.bySemanticsLabel('$moreLabel, 2'), findsOneWidget);

    await tester.tap(find.text('+2'));
    await tester.pumpAndSettle();
    expect(find.text('notice 4'), findsOneWidget);
    expect(find.text('notice 5'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets(
    'outside the centered card remains interactive and unpaused',
    (tester) async {
      late OverlayState overlay;
      var underlyingTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              overlay = Overlay.of(context);
              return Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 120,
                    height: 60,
                    child: ElevatedButton(
                      onPressed: () => underlyingTaps += 1,
                      child: const Text('underlying'),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      showTopToast(
        overlay,
        message: 'centered toast',
        duration: const Duration(seconds: 1),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final underlying = find.text('underlying');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(underlying));
      await tester.pump();
      await tester.tap(underlying);
      await tester.pump();
      expect(underlyingTaps, 1);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('centered toast'), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('safe coalescing refreshes lifetime but keeps actions distinct', (
    tester,
  ) async {
    late OverlayState overlay;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            overlay = Overlay.of(context);
            return const Scaffold();
          },
        ),
      ),
    );

    showTopToast(
      overlay,
      message: 'repeated',
      duration: const Duration(seconds: 2),
    );
    await tester.pump(const Duration(milliseconds: 1500));
    showTopToast(
      overlay,
      message: 'repeated',
      duration: const Duration(seconds: 2),
    );
    await tester.pump();
    expect(find.text('repeated'), findsOneWidget);
    expect(find.text('×2'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('repeated'), findsOneWidget);

    showTopToast(
      overlay,
      message: 'actionable',
      duration: const Duration(minutes: 1),
      actionLabel: 'First',
      onAction: () {},
    );
    showTopToast(
      overlay,
      message: 'actionable',
      duration: const Duration(minutes: 1),
      actionLabel: 'Second',
      onAction: () {},
    );
    await tester.pump();
    expect(find.text('actionable'), findsNWidgets(2));

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('repeated'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('overflow history remains bounded during a burst', (
    tester,
  ) async {
    late OverlayState overlay;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            overlay = Overlay.of(context);
            return const Scaffold();
          },
        ),
      ),
    );
    for (var i = 0; i < 60; i++) {
      showTopToast(
        overlay,
        message: 'burst $i',
        duration: const Duration(minutes: 1),
      );
    }
    await tester.pump();
    expect(find.text('+50'), findsOneWidget);
    await tester.tap(find.text('+50'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('persistent notices are live regions with an explicit close', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    late OverlayState overlay;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            overlay = Overlay.of(context);
            return const Scaffold();
          },
        ),
      ),
    );

    showTopToast(
      overlay,
      message: 'Recovery required',
      dismissal: TopToastDismissal.persistent,
    );
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Recovery required'), findsOneWidget);
    expect(find.bySemanticsLabel('Recovery required'), findsOneWidget);
    final liveRegion = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.liveRegion == true &&
            widget.properties.label == 'Recovery required',
      ),
    );
    expect(liveRegion.properties.liveRegion, isTrue);
    expect(find.byTooltip('Close'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Recovery required'), findsNothing);
    semantics.dispose();
  });

  testWidgets('hover and focus independently pause the remaining lifetime', (
    tester,
  ) async {
    late OverlayState overlay;
    final outsideFocusNode = FocusNode();
    addTearDown(outsideFocusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            overlay = Overlay.of(context);
            return Scaffold(body: TextField(focusNode: outsideFocusNode));
          },
        ),
      ),
    );
    showTopToast(
      overlay,
      message: 'paused',
      duration: const Duration(seconds: 2),
      actionLabel: 'Keep',
      onAction: () {},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.text('paused')));
    await tester.pump();
    final actionFocusNode = Focus.of(tester.element(find.text('Keep')));
    actionFocusNode.requestFocus();
    await tester.pump();
    expect(actionFocusNode.hasFocus, isTrue);
    await mouse.moveTo(const Offset(1, 599));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('paused'), findsOneWidget);

    outsideFocusNode.requestFocus();
    await tester.pump();
    expect(outsideFocusNode.hasFocus, isTrue);
    expect(actionFocusNode.hasFocus, isFalse);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('paused'), findsNothing);
  });

  group('with a screen reader', () {
    Future<OverlayState> pumpHost(
      WidgetTester tester, {
      required ValueNotifier<bool> screenReader,
    }) async {
      late OverlayState overlay;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: screenReader,
            builder: (context, on, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(accessibleNavigation: on),
              child: child!,
            ),
          ),
          home: Builder(
            builder: (context) {
              overlay = Overlay.of(context);
              return const Scaffold();
            },
          ),
        ),
      );
      return overlay;
    }

    testWidgets('a toast with an action stays until it is closed', (
      tester,
    ) async {
      final screenReader = ValueNotifier(true);
      addTearDown(screenReader.dispose);
      final overlay = await pumpHost(tester, screenReader: screenReader);

      showTopToast(
        overlay,
        message: 'Unlock failed',
        duration: const Duration(seconds: 2),
        actionLabel: 'Retry',
        onAction: () {},
      );
      showTopToast(
        overlay,
        message: 'Copied',
        duration: const Duration(seconds: 2),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      // The action outlives its timer; the actionless notice still expires.
      expect(find.text('Unlock failed'), findsOneWidget);
      expect(find.text('Copied'), findsNothing);
      expect(find.byTooltip('Close'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Unlock failed'), findsNothing);
    });

    testWidgets('turning the screen reader off resumes the timer', (
      tester,
    ) async {
      final screenReader = ValueNotifier(true);
      addTearDown(screenReader.dispose);
      final overlay = await pumpHost(tester, screenReader: screenReader);

      showTopToast(
        overlay,
        message: 'Unlock failed',
        duration: const Duration(seconds: 2),
        actionLabel: 'Retry',
        onAction: () {},
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Unlock failed'), findsOneWidget);

      screenReader.value = false;
      await tester.pump();
      expect(find.byTooltip('Close'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Unlock failed'), findsNothing);
    });
  });

  testWidgets('notices that are never shown are announced', (tester) async {
    late OverlayState overlay;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            overlay = Overlay.of(context);
            return const Scaffold();
          },
        ),
      ),
    );

    for (var i = 1; i <= 4; i++) {
      showTopToast(
        overlay,
        message: 'notice $i',
        duration: const Duration(minutes: 1),
      );
    }
    await tester.pump();
    // Visible toasts reach the screen reader as live regions; only the
    // overflowed one needs an announcement.
    expect(tester.takeAnnouncements().map((a) => a.message), ['notice 4']);

    // A repeat of the overflowed notice is announced again.
    showTopToast(
      overlay,
      message: 'notice 4',
      duration: const Duration(minutes: 1),
    );
    await tester.pump();
    expect(tester.takeAnnouncements().map((a) => a.message), ['notice 4']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a coalesced repeat of a visible notice is announced', (
    tester,
  ) async {
    late OverlayState overlay;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            overlay = Overlay.of(context);
            return const Scaffold();
          },
        ),
      ),
    );

    showTopToast(overlay, message: 'Connection lost');
    await tester.pump();
    expect(tester.takeAnnouncements(), isEmpty);

    showTopToast(overlay, message: 'Connection lost');
    await tester.pump();
    expect(find.text('×2'), findsOneWidget);
    expect(tester.takeAnnouncements().map((a) => a.message), [
      'Connection lost',
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('toast strip stays bounded with narrow large-text content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late OverlayState overlay;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.5)),
          child: child!,
        ),
        home: Builder(
          builder: (context) {
            overlay = Overlay.of(context);
            return const Scaffold();
          },
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      showTopToast(
        overlay,
        message: 'A long recovery notification that must remain readable $i',
        dismissal: TopToastDismissal.persistent,
        actionLabel: 'Review',
        onAction: () {},
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    final scrollView = tester.renderObject<RenderBox>(
      find.byType(SingleChildScrollView),
    );
    expect(scrollView.size.height, lessThanOrEqualTo(180));
    await tester.pumpWidget(const SizedBox());
  });
}
