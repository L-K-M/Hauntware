// Adapted from Seance app/seance_app/test/server_mark_picker_test.dart @
// 66411c1; re-diffed at d811309; see docs/PORTS.md. Since 2026-10-08 the
// picker is ghost_marks' and its suite lives there; this keeps the wrapper
// opening it in this app's words on the server's accent.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/server_appearance.dart';
import 'package:poltergeist_app/ui/server_mark_picker.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  testWidgets('previews use the server accent', (tester) async {
    const accent = ServerTint(named: ServerColor.red);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showServerMarkPicker(
                context,
                current: const ServerGlyphMark(null),
                accent: accent,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final badges = tester.widgetList<ServerBadge>(find.byType(ServerBadge));
    expect(badges, isNotEmpty);
    expect(badges.map((badge) => badge.tint), everyElement(accent));
    expect(find.byType(ServerAccentBar), findsNothing);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.serverMarkPickerTitle), findsOneWidget);
    expect(find.text(l10n.serverMarkPickerIconsTab), findsOneWidget);
  });
}
