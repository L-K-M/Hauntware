// The shell's one-session guard (02 §8.1): a command that opens a dialog
// holds its session until the dialog closes, and commands gated on that
// guard stay disabled for the whole of it — even when another app command
// runs meanwhile (the macOS menu bar stays live under an in-app dialog).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';
import 'package:poltergeist_app/ui/import/ssh_config_import_command.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_ssh_config_source.dart';
import '../../support/shell_commands.dart';

const _home = '/home/tester';
const _configPath = '$_home/.ssh/config';

/// An empty store: the import preview only needs something to diff against.
class _EmptyBookmarkStore implements BookmarkRepository {
  @override
  Future<List<Bookmark>> load() async => const [];

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {}
}

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      PoltergeistApp(
        sshConfigImport: SshConfigImportSetup(
          service: SshConfigImportService(
            homeDirectory: _home,
            source: FakeSshConfigSource({
              _configPath: 'Host web\n  HostName web.example.com\n',
            }),
            mintId: () => 'row',
          ),
          bookmarks: _EmptyBookmarkStore(),
          configPath: _configPath,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an app command run during another session leaves that '
      'session guarded until it ends', (tester) async {
    await pumpApp(tester);
    expect(shellCommandEnabled(tester, kSshConfigImportCommandId), isTrue);

    // The import's preview holds its session open.
    await runShellCommand(tester, kSshConfigImportCommandId);
    expect(find.text('Import servers from ssh config'), findsOneWidget);
    expect(shellCommandEnabled(tester, kSshConfigImportCommandId), isFalse);

    // An always-enabled app command starts and finishes meanwhile.
    await runShellCommand(tester, kViewToggleSecondPaneCommandId);
    expect(
      shellCommandEnabled(tester, kSshConfigImportCommandId),
      isFalse,
      reason: 'the preview is still open',
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Import servers from ssh config'), findsNothing);
    expect(shellCommandEnabled(tester, kSshConfigImportCommandId), isTrue);
  });

  Future<void> closeDialog(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  }

  testWidgets('Connect holds its session until its dialog closes', (
    tester,
  ) async {
    await pumpApp(tester);

    await runShellCommand(tester, kConnectQuickConnectCommandId);
    expect(find.byType(Dialog), findsOneWidget);
    expect(shellCommandEnabled(tester, kSshConfigImportCommandId), isFalse);

    await closeDialog(tester);
    expect(shellCommandEnabled(tester, kSshConfigImportCommandId), isTrue);
  });

  testWidgets('a command run from its chord holds a session too', (
    tester,
  ) async {
    await pumpApp(tester);
    await runShellCommand(tester, kPaneFocusLeftCommandId);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(shellCommandEnabled(tester, kSshConfigImportCommandId), isFalse);

    await closeDialog(tester);
    expect(shellCommandEnabled(tester, kSshConfigImportCommandId), isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
