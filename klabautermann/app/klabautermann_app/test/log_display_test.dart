// A11Y-12: every log view's text size and wrapping, kept per device and
// set in Settings > General.
import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/log_display.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/logs/log_view.dart';
import 'package:klabautermann_app/ui/logs/log_view_controller.dart';

void main() {
  test('a text size outside the offered ones is clamped', () {
    expect(LogDisplay(textSize: 4).textSize, kLogTextSizeMin);
    expect(LogDisplay(textSize: 40).textSize, kLogTextSizeMax);
    expect(LogDisplay().textSize, kLogTextSizeDefault);
  });

  test('a change applies before it is saved, says when it was not saved, '
      'and picking it again retries the save', () async {
    final saved = <(int, bool)>[];
    var failing = true;
    final display = LogDisplayController(
      save: (size, wrap) async {
        if (failing) throw const FileSystemException('disk full');
        saved.add((size, wrap));
      },
    );
    addTearDown(display.dispose);
    final big = LogDisplay(textSize: 16, wrap: LogWrap.on);

    await expectLater(
      display.setLogDisplay(big),
      throwsA(isA<LogDisplayNotSavedException>()),
    );
    expect(display.value, big, reason: 'it still applies');

    failing = false;
    await display.setLogDisplay(big);
    expect(saved, [(16, true)]);
    await display.setLogDisplay(big);
    expect(saved, hasLength(1), reason: 'in force and saved');
  });

  testWidgets('log views draw at the device\'s text size and wrap as it '
      'says, unless a view picks its own wrapping', (tester) async {
    tester.view.physicalSize = const Size(300, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final display = LogDisplayController();
    final logs = LogViewController()..add(['short', 'long ' * 40]);
    addTearDown(() {
      display.dispose();
      logs.dispose();
    });
    Future<void> pump({LogWrap? wrap}) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LogDisplayScope(
          display: display,
          child: Material(
            child: LogView(controller: logs, wrap: wrap),
          ),
        ),
      ),
    );
    double rowHeight(int row) =>
        tester.getSize(find.byType(RichText).at(row)).height;

    await pump();
    final line = rowHeight(0);
    expect(rowHeight(1), line, reason: 'cut at the edge');

    await display.setLogDisplay(LogDisplay(textSize: kLogTextSizeMax));
    await tester.pump();
    expect(rowHeight(0), greaterThan(line));
    final bigLine = rowHeight(0);

    await display.setLogDisplay(
      LogDisplay(textSize: kLogTextSizeMax, wrap: LogWrap.on),
    );
    await tester.pump();
    expect(rowHeight(1), greaterThan(bigLine), reason: 'wrapped');

    await pump(wrap: LogWrap.off);
    expect(rowHeight(1), bigLine, reason: 'the view\'s own choice wins');
  });
}
