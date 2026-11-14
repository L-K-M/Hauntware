import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/settings/setting_write.dart';

final class _NotSaved implements Exception {}

/// The settings tabs' one way to word a change: nothing when it saved, a
/// not-saved toast for the controller's own exception, a not-changed one
/// for anything else, and none once the write no longer applies.
void main() {
  Future<BuildContext> pump(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return context;
  }

  Future<SettingWrite> write(
    BuildContext context,
    Future<void> Function() change, {
    bool Function()? report,
  }) => writeSetting<_NotSaved>(
    context,
    change,
    notSaved: (_) => 'not saved',
    notChanged: (_) => 'not changed',
    report: report,
  );

  testWidgets('a saved change says nothing', (tester) async {
    final context = await pump(tester);
    expect(await write(context, () async {}), SettingWrite.saved);
    await tester.pump();
    expect(find.text('not saved'), findsNothing);
    expect(find.text('not changed'), findsNothing);
  });

  testWidgets('the controller\'s not-saved exception and any other each '
      'have their words', (tester) async {
    final context = await pump(tester);
    expect(
      await write(context, () async => throw _NotSaved()),
      SettingWrite.notSaved,
    );
    await tester.pump();
    expect(find.text('not saved'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    expect(
      await write(context, () async => throw const FormatException()),
      SettingWrite.notChanged,
    );
    await tester.pump();
    expect(find.text('not changed'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('a write that no longer applies reports nothing', (tester) async {
    final context = await pump(tester);
    expect(
      await write(context, () async => throw _NotSaved(), report: () => false),
      SettingWrite.notSaved,
    );
    await tester.pump();
    expect(find.text('not saved'), findsNothing);
  });
}
