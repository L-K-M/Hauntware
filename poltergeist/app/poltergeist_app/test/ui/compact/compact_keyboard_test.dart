import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/ui/compact/compact_listing.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart'
    show FakePaneLanes, FakePaneChannel;

void main() {
  testWidgets(
    'compact hardware keys select, scroll, open and leave empty folders',
    (tester) async {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/home/test');
      channel.listings['/home/test'] = [
        const RemoteFileEntry(
          path: '/home/test/docs',
          name: 'docs',
          type: RemoteFileType.directory,
        ),
        for (var i = 0; i < 100; i++)
          RemoteFileEntry(
            path: '/home/test/file$i',
            name: 'file$i',
            type: RemoteFileType.file,
          ),
      ];
      channel.listings['/home/test/docs'] = [];
      lanes.nextLocalChannel = channel;
      final pane = PaneController(paneTabId: 'compact', lanes: lanes);
      addTearDown(pane.dispose);
      await pane.openLocalHome();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CompactListing(
              controller: pane,
              selecting: false,
              onCancelRecovery: () {},
              callbacks: CompactRowCallbacks(
                onTap: (_, _) {},
                onLongPress: (_, _) {},
                onActions: (_, _) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('docs'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(pane.cursorIndex, 0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(pane.cursorIndex, greaterThan(1));
      expect(pane.selectedCount, greaterThan(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(pane.cursorIndex, 100);
      expect(find.text('file99').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(pane.location?.path, '/home/test/docs');
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(pane.location?.path, '/home/test');
    },
  );
}
