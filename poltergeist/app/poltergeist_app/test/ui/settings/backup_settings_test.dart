// Widget coverage for 04 §4.3/§4.4: the enrollment form's gating and
// verbatim outcomes, the enrolled surface's states and actions, and the
// B→A switch dialog's phases. With POLTERGEIST_CAPTURE=1 each state also
// lands as a PNG under tasks/run3-task81/captures (or
// POLTERGEIST_CAPTURE_DIR) with real fonts when the host provides them.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/bookmark_backup_service.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_app/services/secure_master_key.dart'
    show MasterKeyUnavailableException;
import 'package:poltergeist_app/services/sync_account_gate.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/settings/backup_enrollment_form.dart';
import 'package:poltergeist_app/ui/settings/backup_settings.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_sync_backup.dart';

const _gateOffered = SyncAccountGate(
  minimumSharedVersion: 'v9.9.9-test',
  sharedIncludesSeance56Fix: false,
);

const _gateFixed = SyncAccountGate(
  minimumSharedVersion: 'v9.9.9-test',
  sharedIncludesSeance56Fix: true,
);

const _gateClosed = SyncAccountGate(
  minimumSharedVersion: null,
  sharedIncludesSeance56Fix: false,
);

final class _Harness {
  final server = FakeSyncServer();
  final transports = <FakeSyncTransport>[];
  final credentials = FakeSyncCredentialStore();
  final retained = FakeRetainedSyncTokenStore();
  final state = FakeSyncEnrollmentState();
  final bookmarks = FakeSyncTrackingBookmarkStore();
  final servers = FakeSyncTrackingServerStore();
  final vaultStore = InMemoryVaultStore();
  final hostKeys = InMemoryConflictAwareHostKeyStore();
  final pinVerdicts = InMemoryPinVerdictStore();
  final tripwires = InMemorySyncTripwireStore();
  var records = InMemorySyncRecordStore();

  late final BookmarkBackupService service = BookmarkBackupService(
    credentials: credentials,
    retainedTokens: retained,
    enrollmentState: state,
    records: records,
    resetRecords: () async => records = InMemorySyncRecordStore(),
    bookmarks: bookmarks,
    hostKeys: hostKeys,
    pinVerdicts: pinVerdicts,
    tripwires: tripwires,
    transportFactory: fakeTransportFactory(server, transports),
    vaultKey: () async => credentials.vaultKey,
    servers: servers,
    vaultStore: vaultStore,
  );

  /// Enroll directly in [mode] and load the service — the starting state
  /// for every enrolled-surface test.
  Future<BookmarkBackupService> enrolled({
    SyncAccountMode mode = SyncAccountMode.separate,
    String username = 'ghost-abcd1234',
  }) async {
    state.enrolled = SyncAccount(
      baseUrl: 'https://sync.example',
      username: username,
      mode: mode,
    );
    credentials.token = 'token-$username';
    credentials.vaultKey = List.filled(32, 5);
    final service = this.service;
    await service.load();
    return service;
  }
}

extension on _Harness {
  /// A conflicting `hostkey:` record sealed under the enrolled vault key
  /// — the coordinator's quarantine surfaces it on load.
  Future<void> seedPinConflict({
    String host = 'conflict.example.com',
    int port = 22,
  }) async {
    await hostKeys.put(
      HostKey(
        host: host,
        port: port,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:local',
        pinnedAt: 1,
      ),
    );
    final crypto = RecordCrypto(RecordCodec(credentials.vaultKey!));
    await records.putRemote(
      await crypto.seal(
        DecryptedRecord(
          id: 'hostkey:$host:$port',
          kind: RecordKind.hostKey,
          updatedAt: 4000,
          deviceId: 'fleet-device',
          data: HostKey(
            host: host,
            port: port,
            type: 'ssh-ed25519',
            fingerprintSha256: 'SHA256:fleet',
            pinnedAt: 2,
          ).toJson(),
        ),
      ),
    );
  }
}

/// The enrolled view's model with scripted retained-account state:
/// §4.4's optional delete has no real-service path without a durable
/// settings document, and widget tests stay off the filesystem.
final class _FakeBackupModel extends ChangeNotifier
    implements BackupSettingsModel {
  _FakeBackupModel({
    required this.account,
    required this.retainedAccount,
    required this.deleteSeparateOffered,
  });

  @override
  final SyncAccount? account;

  @override
  bool syncing = false;

  @override
  bool syncSecrets = false;

  @override
  Set<String> notices = {};

  @override
  bool passphraseUnverified = false;

  @override
  List<HostKeyConflict> pinConflicts = [];

  @override
  Set<String> trippedIds = {};

  @override
  String? quarantinedPath;

  @override
  DateTime? lastSyncAt;

  @override
  String? lastSyncError;

  @override
  final RetainedBackupAccount? retainedAccount;

  @override
  final bool deleteSeparateOffered;

  final deleteRetainedCalls = <String>[];

  @override
  Future<void> setSyncSecrets(bool enabled) async {}

  @override
  Future<void> registerSeparate({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async {}

  @override
  Future<void> loginAccount({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
    required SyncAccountMode mode,
  }) async {}

  @override
  Future<void> backUpNow() async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteSeparateAccount({required String confirmedName}) async {}

  @override
  Future<BackupSwitchOutcome> switchToShared({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async => BackupSwitchOutcome(
    held: const [],
    passphraseUnverified: false,
  );

  @override
  Future<void> resolvePinConflict(
    HostKeyConflict conflict, {
    required bool keepLocal,
  }) async {}

  @override
  Future<void> deleteRetainedSeparateAccount({
    required String confirmedName,
  }) async {
    deleteRetainedCalls.add(confirmedName);
  }

  @override
  Future<void> declineRetainedDelete() async {}
}

Widget _wrap(Widget child, {ThemeData? theme}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: theme ?? buildPoltergeistTheme(Brightness.dark),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Future<void> _pumpSection(
  WidgetTester tester,
  BookmarkBackupService service, {
  SyncAccountGate gate = _gateClosed,
  ThemeData? theme,
  // Typed Key, not ValueKey: a ValueKey<dynamic> context would infer the
  // default as ValueKey<dynamic>, which never =='s the ValueKey<String>
  // _capture looks up (runtimeType mismatch) — and only fails in capture
  // mode, where the lookup actually runs.
  Key captureKey = const ValueKey('backup.capture'),
}) {
  return tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: _wrap(
        BackupSettingsSection(service: service, gate: gate),
        theme: theme,
      ),
    ),
  );
}

Future<void> _enterAll(
  WidgetTester tester, {
  String url = 'https://sync.example',
  String username = 'ghost-abcd1234',
  String password = 'pw',
  String passphrase = 'pw',
  String confirm = 'pw',
}) async {
  await tester.enterText(find.byKey(const ValueKey('backup.enroll.url')), url);
  await tester.enterText(
    find.byKey(const ValueKey('backup.enroll.username')),
    username,
  );
  await tester.enterText(
    find.byKey(const ValueKey('backup.enroll.password')),
    password,
  );
  await tester.enterText(
    find.byKey(const ValueKey('backup.enroll.passphrase')),
    passphrase,
  );
  final confirmField = find.byKey(const ValueKey('backup.enroll.confirm'));
  if (confirmField.evaluate().isNotEmpty) {
    await tester.enterText(confirmField, confirm);
  }
}

/// Pasted and typed secrets stay out of the keyboard's learning (#625).
void _expectNoLearning(WidgetTester tester, String key) {
  final secret = tester.widget<TextField>(find.byKey(ValueKey(key)));
  expect(secret.autocorrect, isFalse, reason: key);
  expect(secret.enableSuggestions, isFalse, reason: key);
  expect(secret.enableIMEPersonalizedLearning, isFalse, reason: key);
}

/// Tap a widget that may sit below the fold of the scroll view — the
/// default 800×600 viewport leaves the form's tail untouchable.
Future<void> _tapVisible(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
}

/// Let a real-async enrollment or switch finish. Argon2id's derive
/// awaits spawned isolates on the real event loop, while the futures the
/// tapped handler chained to them resume on the fake zone's microtask
/// queue — so progress needs alternating real turns ([runAsync]) and
/// fake flushes ([pump]). A dozen rounds covers the derive's internal
/// stages with margin; the work itself is sub-second.
Future<void> _settleRealAsync(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
  }
  await tester.pumpAndSettle();
}

bool _enabled(WidgetTester tester, Key key) {
  final widget = tester.widget(find.byKey(key));
  return switch (widget) {
    FilledButton(onPressed: final p) => p != null,
    TextButton(onPressed: final p) => p != null,
    ListTile(enabled: final e) => e,
    // A silent false would read as "disabled" — a new widget kind must
    // extend this switch, not inherit a wrong answer.
    _ => throw StateError(
      'unhandled widget type for $key: ${widget.runtimeType}',
    ),
  };
}

// --- Capture helpers (house convention, see quit_dialog_capture_test) ---

final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task81/captures';

bool get _captureOn => Platform.environment['POLTERGEIST_CAPTURE'] == '1';

Future<ByteData> _fontBytes(String path) async =>
    ByteData.sublistView(File(path).readAsBytesSync());

Future<void> _loadRealFonts() async {
  final home = Platform.environment['HOME'];
  final dir =
      Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      (home == null ? '' : '$home/.local/share/fonts');
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(_fontBytes(icons.path));
    await iconsLoader.load();
  }
  if (!sans.existsSync()) return;
  final loader = FontLoader('DejaVu Sans')..addFont(_fontBytes(sans.path));
  if (sansBold.existsSync()) loader.addFont(_fontBytes(sansBold.path));
  await loader.load();
}

ThemeData get _captureTheme {
  final base = buildPoltergeistTheme(Brightness.dark);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'DejaVu Sans'),
  );
}

Future<void> _capture(
  WidgetTester tester,
  String name, {
  Key key = const ValueKey('backup.capture'),
}) async {
  if (!_captureOn) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final bytes = (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
  final file = File('$_captureDir/$name.png');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

void main() {
  late _Harness h;

  setUp(() => h = _Harness());

  group('enrollment form (04 §4.3)', () {
    test('a refused re-key over a lost vault key gets its own status', () {
      final l10n = lookupAppLocalizations(const Locale('en'));

      expect(
        describeEnrollmentError(l10n, const MasterKeyUnavailableException()),
        l10n.backupVaultKeyMissing,
      );
    });

    testWidgets('D32: preselects the shared Séance account when offered', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _pumpSection(tester, h.service, gate: _gateOffered);
      await tester.pumpAndSettle();

      final group = tester.widget<RadioGroup<SyncAccountMode>>(
        find.byType(RadioGroup<SyncAccountMode>),
      );
      expect(group.groupValue, SyncAccountMode.shared);
      // Shared accounts log in; the register/login segment is hidden and
      // Continue still waits on the fleet assertion.
      expect(find.byKey(const ValueKey('backup.enroll.action')), findsNothing);
      expect(
        find.byKey(const ValueKey('backup.fleet.checkbox')),
        findsOneWidget,
      );
      // The separate account stays reachable.
      expect(
        find.byKey(const ValueKey('backup.mode.separate')),
        findsOneWidget,
      );
    });

    testWidgets('secret fields keep the keyboard from learning them', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _pumpSection(tester, h.service);
      await tester.pumpAndSettle();
      _expectNoLearning(tester, 'backup.enroll.password');
      _expectNoLearning(tester, 'backup.enroll.passphrase');
      _expectNoLearning(tester, 'backup.enroll.confirm');
    });

    testWidgets('a closed gate preselects Design B with the verbatim copy', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _pumpSection(tester, h.service);
      await tester.pumpAndSettle();

      expect(find.text('Bookmark backup'), findsOneWidget);
      expect(
        find.textContaining('Nothing readable ever leaves this device'),
        findsOneWidget,
      );
      // Design B's radio is checked; the register segment is its action.
      expect(
        find.byKey(const ValueKey('backup.mode.separate')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('backup.enroll.action')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('backup.enroll.confirm')),
        findsOneWidget,
      );
      // §4.3's callout, verbatim.
      expect(
        find.textContaining(
          'The encryption passphrase never leaves your devices',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a null gate tag disables the shared option outright', (
      tester,
    ) async {
      await _pumpSection(tester, h.service, gate: _gateClosed);
      await tester.pumpAndSettle();

      expect(_enabled(tester, const ValueKey('backup.mode.shared')), isFalse);
      // Tapping the disabled tile must not select it — the RadioGroup
      // ancestor would otherwise take the tap through the Radio leaf.
      await tester.tap(find.byKey(const ValueKey('backup.mode.shared')));
      await tester.pumpAndSettle();
      final group = tester.widget<RadioGroup<SyncAccountMode>>(
        find.byType(RadioGroup<SyncAccountMode>),
      );
      expect(group.groupValue, isNot(SyncAccountMode.shared));
      // No fleet checkbox — the gated copy cannot render without the tag.
      expect(find.byKey(const ValueKey('backup.fleet.checkbox')), findsNothing);
    });

    testWidgets('the shared option gates Continue on the fleet checkbox '
        'and shows the Séance #56 disclosure', (tester) async {
      await _pumpSection(tester, h.service, gate: _gateOffered);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('backup.mode.shared')));
      await tester.pumpAndSettle();

      // The verbatim shared copy interpolates the recorded tag.
      expect(find.textContaining('v9.9.9-test'), findsWidgets);
      expect(
        find.byKey(const ValueKey('backup.fleet.checkbox')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('backup.shared.disclosure')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'accept synced host-key pins without a conflict warning',
        ),
        findsOneWidget,
      );
      // Shared is login-only: no register segment, no confirm field.
      expect(find.byKey(const ValueKey('backup.enroll.action')), findsNothing);
      expect(find.byKey(const ValueKey('backup.enroll.confirm')), findsNothing);
      // Continue waits on the fleet assertion.
      expect(
        _enabled(tester, const ValueKey('backup.enroll.continue')),
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('backup.fleet.checkbox')));
      await tester.pumpAndSettle();
      expect(
        _enabled(tester, const ValueKey('backup.enroll.continue')),
        isTrue,
      );
    });

    testWidgets('the disclosure disappears when the recorded tag carries '
        'the Séance #56 fix', (tester) async {
      await _pumpSection(tester, h.service, gate: _gateFixed);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup.mode.shared')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('backup.shared.disclosure')),
        findsNothing,
      );
    });

    testWidgets('validation failures land in the live-region status', (
      tester,
    ) async {
      await _pumpSection(tester, h.service);
      await tester.pumpAndSettle();
      await _tapVisible(tester, const ValueKey('backup.enroll.continue'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('backup.enroll.status')),
        findsOneWidget,
      );
      expect(
        find.text('Enter a valid HTTP or HTTPS server URL.'),
        findsOneWidget,
      );
    });

    testWidgets('Return in the last field submits like Continue', (
      tester,
    ) async {
      await _pumpSection(tester, h.service);
      await tester.pumpAndSettle();
      await _enterAll(tester);

      await tester.showKeyboard(
        find.byKey(const ValueKey('backup.enroll.confirm')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settleRealAsync(tester);

      expect(find.byKey(const ValueKey('backup.enrolled')), findsOneWidget);
    });

    testWidgets('Return in an earlier field moves on without submitting', (
      tester,
    ) async {
      await _pumpSection(tester, h.service);
      await tester.pumpAndSettle();
      await _enterAll(tester);

      await tester.showKeyboard(
        find.byKey(const ValueKey('backup.enroll.url')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();

      expect(find.byKey(const ValueKey('backup.enrolled')), findsNothing);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const ValueKey('backup.enroll.username')),
                matching: find.byType(EditableText),
              ),
            )
            .focusNode
            .hasFocus,
        isTrue,
      );
    });

    testWidgets('Return stays inert while Continue is gated', (tester) async {
      await _pumpSection(tester, h.service, gate: _gateOffered);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup.mode.shared')));
      await tester.pumpAndSettle();
      await _enterAll(tester);

      await tester.showKeyboard(
        find.byKey(const ValueKey('backup.enroll.passphrase')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settleRealAsync(tester);

      // The fleet assertion is unchecked: no submission, no status.
      expect(find.byKey(const ValueKey('backup.enrolled')), findsNothing);
      expect(find.byKey(const ValueKey('backup.enroll.status')), findsNothing);
    });

    testWidgets('registration closed reports the verbatim §4.3 copy', (
      tester,
    ) async {
      h.server.registrationClosed = true;
      await _pumpSection(tester, h.service);
      await tester.pumpAndSettle();
      await _enterAll(tester);
      await _tapVisible(tester, const ValueKey('backup.enroll.continue'));
      await _settleRealAsync(tester);
      expect(find.textContaining('registration closed'), findsOneWidget);
      expect(find.textContaining('SEANCE_OPEN_REGISTRATION=1'), findsOneWidget);
    });

    testWidgets('a KDF downgrade reports the verbatim refusal', (tester) async {
      h.server.argonParams = const Argon2Params.fast();
      await _pumpSection(tester, h.service);
      await tester.pumpAndSettle();
      // Login mode exercises the prelogin path.
      await tester.tap(find.text('Log in'));
      await tester.pumpAndSettle();
      await _enterAll(tester);
      await _tapVisible(tester, const ValueKey('backup.enroll.continue'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('refusing to derive your key'),
        findsOneWidget,
      );
    });

    testWidgets('a successful register swaps to the enrolled view', (
      tester,
    ) async {
      await _pumpSection(tester, h.service);
      await tester.pumpAndSettle();
      await _enterAll(tester);
      await _tapVisible(tester, const ValueKey('backup.enroll.continue'));
      await _settleRealAsync(tester);
      expect(find.byKey(const ValueKey('backup.enrolled')), findsOneWidget);
      expect(
        find.textContaining('ghost-abcd1234 on https://sync.example'),
        findsOneWidget,
      );
    });
  });

  group('enrolled view (04 §3.3/§4.2)', () {
    testWidgets('separate mode shows summary, status, and every action', (
      tester,
    ) async {
      final service = await h.enrolled();
      await _pumpSection(tester, service, gate: _gateOffered);
      await tester.pumpAndSettle();

      expect(find.text('Separate backup account'), findsOneWidget);
      expect(
        find.textContaining('ghost-abcd1234 on https://sync.example'),
        findsOneWidget,
      );
      expect(find.text('Not backed up yet.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('backup.enrolled.backupNow')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('backup.enrolled.signOut')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('backup.enrolled.switch')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('backup.enrolled.delete')),
        findsOneWidget,
      );
      // Credentials never travel on a separate account.
      expect(
        find.byKey(const ValueKey('backup.enrolled.syncSecrets')),
        findsNothing,
      );
    });

    testWidgets('a closed gate hides the switch button', (tester) async {
      final service = await h.enrolled();
      await _pumpSection(tester, service, gate: _gateClosed);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('backup.enrolled.switch')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('backup.enrolled.delete')),
        findsOneWidget,
      );
    });

    testWidgets('shared mode offers neither delete nor switch', (tester) async {
      final service = await h.enrolled(mode: SyncAccountMode.shared);
      await _pumpSection(tester, service, gate: _gateOffered);
      await tester.pumpAndSettle();
      expect(find.text('Shared Séance account'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('backup.enrolled.delete')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('backup.enrolled.switch')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('backup.enrolled.signOut')),
        findsOneWidget,
      );
    });

    testWidgets('shared mode offers the credential switch, off by default', (
      tester,
    ) async {
      final service = await h.enrolled(mode: SyncAccountMode.shared);
      await _pumpSection(tester, service, gate: _gateOffered);
      await tester.pumpAndSettle();
      const key = ValueKey('backup.enrolled.syncSecrets');
      expect(find.text('Sync saved passwords & keys'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(key)).value, isFalse);

      await _tapVisible(tester, key);
      await tester.pumpAndSettle();
      expect(service.syncSecrets, isTrue);
      expect(tester.widget<SwitchListTile>(find.byKey(key)).value, isTrue);
    });

    testWidgets('the paused hold renders with the separate way-out', (
      tester,
    ) async {
      h.state.unverified = true;
      final service = await h.enrolled();
      await _pumpSection(tester, service);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Backup paused until the passphrase'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Open Poltergeist on another device'),
        findsOneWidget,
      );
    });

    testWidgets('the dead-account notice renders verbatim', (tester) async {
      h.state.raised.add(syncNoticeAccountAuthFailed);
      final service = await h.enrolled();
      await _pumpSection(tester, service);
      await tester.pumpAndSettle();
      expect(find.textContaining('rejected this device'), findsOneWidget);
    });

    testWidgets('a quarantined pin renders the warning with both verbs', (
      tester,
    ) async {
      h.credentials.vaultKey = List.filled(32, 5);
      await tester.runAsync(h.seedPinConflict);
      final service = (await tester.runAsync(h.enrolled))!;
      await _pumpSection(tester, service);
      await tester.pumpAndSettle();
      expect(find.textContaining('conflict.example.com:22'), findsWidgets);
      expect(
        find.byKey(const ValueKey('backup.pin.keep.conflict.example.com:22')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('backup.pin.accept.conflict.example.com:22')),
        findsOneWidget,
      );
      // Both keys show, as in Séance (#56), so the choice can be checked
      // against the server's own fingerprint; the verbs use Séance's words.
      expect(find.text('This device trusts'), findsOneWidget);
      expect(find.text('SHA256:local'), findsOneWidget);
      expect(find.text('The other device synced'), findsOneWidget);
      expect(find.text('SHA256:fleet'), findsOneWidget);
      expect(find.text("Keep this device's key"), findsOneWidget);
      expect(find.text('Trust the new key'), findsOneWidget);
    });

    testWidgets('sign-out asks, then returns to the enrollment form', (
      tester,
    ) async {
      final service = await h.enrolled();
      await _pumpSection(tester, service);
      await tester.pumpAndSettle();
      await _tapVisible(tester, const ValueKey('backup.enrolled.signOut'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('backup.signout.dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('backup.signout.confirm')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('backup.enroll.continue')),
        findsOneWidget,
      );
    });

    testWidgets('the delete dialog arms only on the typed account name', (
      tester,
    ) async {
      final service = await h.enrolled();
      await _pumpSection(tester, service);
      await tester.pumpAndSettle();
      await _tapVisible(tester, const ValueKey('backup.enrolled.delete'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('backup.delete.dialog')),
        findsOneWidget,
      );
      expect(
        _enabled(tester, const ValueKey('backup.delete.confirm')),
        isFalse,
      );
      await tester.enterText(
        find.byKey(const ValueKey('backup.delete.confirmField')),
        'wrong-name',
      );
      await tester.pumpAndSettle();
      expect(
        _enabled(tester, const ValueKey('backup.delete.confirm')),
        isFalse,
      );
      await tester.enterText(
        find.byKey(const ValueKey('backup.delete.confirmField')),
        'ghost-abcd1234',
      );
      await tester.pumpAndSettle();
      expect(_enabled(tester, const ValueKey('backup.delete.confirm')), isTrue);
      await tester.tap(find.byKey(const ValueKey('backup.delete.confirm')));
      await tester.pumpAndSettle();
      expect(h.server.deleteAccountCalls, 1);
      expect(
        find.byKey(const ValueKey('backup.enroll.continue')),
        findsOneWidget,
      );
    });

    testWidgets('Return in the delete field confirms like the button', (
      tester,
    ) async {
      final service = await h.enrolled();
      await _pumpSection(tester, service);
      await tester.pumpAndSettle();
      await _tapVisible(tester, const ValueKey('backup.enrolled.delete'));
      await tester.pumpAndSettle();

      // A wrong name arms nothing: Return is inert.
      await tester.enterText(
        find.byKey(const ValueKey('backup.delete.confirmField')),
        'wrong-name',
      );
      await tester.pumpAndSettle();
      await tester.showKeyboard(
        find.byKey(const ValueKey('backup.delete.confirmField')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('backup.delete.dialog')),
        findsOneWidget,
      );
      expect(h.server.deleteAccountCalls, 0);

      // The exact name arms the button; Return confirms through it, once.
      await tester.enterText(
        find.byKey(const ValueKey('backup.delete.confirmField')),
        'ghost-abcd1234',
      );
      await tester.pumpAndSettle();
      expect(
        _enabled(tester, const ValueKey('backup.delete.confirm')),
        isTrue,
      );
      await tester.showKeyboard(
        find.byKey(const ValueKey('backup.delete.confirmField')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(h.server.deleteAccountCalls, 1);
      expect(
        find.byKey(const ValueKey('backup.delete.dialog')),
        findsNothing,
      );
    });

    testWidgets('Return in the retained delete field confirms like the '
        'button', (tester) async {
      final model = _FakeBackupModel(
        account: SyncAccount(
          baseUrl: 'https://sync.example',
          username: 'fleet-user',
          mode: SyncAccountMode.shared,
        ),
        retainedAccount: const RetainedBackupAccount(
          baseUrl: 'https://sync.example',
          username: 'old-user',
        ),
        deleteSeparateOffered: true,
      );
      addTearDown(model.dispose);
      await tester.pumpWidget(_wrap(BackupSettingsSection(service: model)));
      await tester.pumpAndSettle();

      await _tapVisible(
        tester,
        const ValueKey('backup.enrolled.deleteRetained'),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('backup.deleteRetained.dialog')),
        findsOneWidget,
      );

      // A wrong name arms nothing: Return is inert.
      await tester.enterText(
        find.byKey(const ValueKey('backup.deleteRetained.confirmField')),
        'wrong-name',
      );
      await tester.pumpAndSettle();
      expect(
        _enabled(tester, const ValueKey('backup.deleteRetained.confirm')),
        isFalse,
      );
      await tester.showKeyboard(
        find.byKey(const ValueKey('backup.deleteRetained.confirmField')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('backup.deleteRetained.dialog')),
        findsOneWidget,
      );
      expect(model.deleteRetainedCalls, isEmpty);

      // The exact name arms the button; Return confirms through it, once.
      await tester.enterText(
        find.byKey(const ValueKey('backup.deleteRetained.confirmField')),
        'old-user',
      );
      await tester.pumpAndSettle();
      expect(
        _enabled(tester, const ValueKey('backup.deleteRetained.confirm')),
        isTrue,
      );
      await tester.showKeyboard(
        find.byKey(const ValueKey('backup.deleteRetained.confirmField')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(model.deleteRetainedCalls, ['old-user']);
      expect(
        find.byKey(const ValueKey('backup.deleteRetained.dialog')),
        findsNothing,
      );
    });
  });

  group('B→A switch dialog (04 §4.4)', () {
    testWidgets('secret fields keep the keyboard from learning them', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(760, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final service = await h.enrolled();
      await _pumpSection(tester, service, gate: _gateOffered);
      await tester.pumpAndSettle();
      await _tapVisible(tester, const ValueKey('backup.enrolled.switch'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup.switch.fleet')));
      await tester.pumpAndSettle();

      _expectNoLearning(tester, 'backup.switch.password');
      _expectNoLearning(tester, 'backup.switch.passphrase');
    });

    testWidgets('the confirm phase gates on the fleet checkbox and walks '
        'to done', (tester) async {
      tester.view.physicalSize = const Size(760, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final service = await h.enrolled();
      await _pumpSection(tester, service, gate: _gateOffered);
      await tester.pumpAndSettle();
      await _tapVisible(tester, const ValueKey('backup.enrolled.switch'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('backup.switch.dialog')),
        findsOneWidget,
      );
      expect(
        _enabled(tester, const ValueKey('backup.switch.continue')),
        isFalse,
      );
      // The disclosure restates at the point of commitment.
      expect(
        find.textContaining(
          'accept synced host-key pins without a conflict warning',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('backup.switch.fleet')));
      await tester.pumpAndSettle();
      expect(
        _enabled(tester, const ValueKey('backup.switch.continue')),
        isTrue,
      );

      // The separate account's URL is prefilled; complete the login.
      await tester.enterText(
        find.byKey(const ValueKey('backup.switch.username')),
        'fleet',
      );
      await tester.enterText(
        find.byKey(const ValueKey('backup.switch.password')),
        'pw',
      );
      await tester.enterText(
        find.byKey(const ValueKey('backup.switch.passphrase')),
        'pw',
      );
      await tester.tap(find.byKey(const ValueKey('backup.switch.continue')));
      await _settleRealAsync(tester);

      // No conflicts on an empty shared account → straight to done.
      expect(find.byKey(const ValueKey('backup.switch.done')), findsOneWidget);
      expect(service.account!.mode, SyncAccountMode.shared);
    });

    testWidgets('Return in the passphrase field submits like Continue', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(760, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final service = await h.enrolled();
      await _pumpSection(tester, service, gate: _gateOffered);
      await tester.pumpAndSettle();
      await _tapVisible(tester, const ValueKey('backup.enrolled.switch'));
      await tester.pumpAndSettle();
      for (final field in ['username', 'password', 'passphrase']) {
        await tester.enterText(
          find.byKey(ValueKey('backup.switch.$field')),
          field == 'username' ? 'fleet' : 'pw',
        );
      }

      // Gated until the fleet assertion: Return does nothing.
      await tester.showKeyboard(
        find.byKey(const ValueKey('backup.switch.passphrase')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settleRealAsync(tester);
      expect(find.byKey(const ValueKey('backup.switch.done')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('backup.switch.fleet')));
      await tester.pumpAndSettle();
      await tester.showKeyboard(
        find.byKey(const ValueKey('backup.switch.passphrase')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settleRealAsync(tester);

      expect(find.byKey(const ValueKey('backup.switch.done')), findsOneWidget);
    });

    testWidgets('a quarantined pull lands on the conflicts phase and '
        'resolves one locator at a time', (tester) async {
      tester.view.physicalSize = const Size(760, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final service = await h.enrolled();
      // The fleet pulls a conflicting pin — sealed under the vault key
      // the shared login ('pw'/'pw') derives.
      await tester.runAsync(
        () => h.hostKeys.put(
          const HostKey(
            host: 'conflict.example.com',
            type: 'ssh-ed25519',
            fingerprintSha256: 'SHA256:local',
            pinnedAt: 1,
          ),
        ),
      );
      final sharedKeys = await tester.runAsync(
        () => VaultCrypto.deriveKeys(
          passphrase: 'pw',
          salt: List.filled(16, 0),
          params: const Argon2Params(),
        ),
      );
      final fleetCrypto = RecordCrypto(RecordCodec(sharedKeys!.vaultKey));
      final fleetRecord = await tester.runAsync(
        () => fleetCrypto.seal(
          DecryptedRecord(
            id: 'hostkey:conflict.example.com:22',
            kind: RecordKind.hostKey,
            updatedAt: 4000,
            deviceId: 'fleet-device',
            data: const HostKey(
              host: 'conflict.example.com',
              type: 'ssh-ed25519',
              fingerprintSha256: 'SHA256:fleet',
              pinnedAt: 2,
            ).toJson(),
          ),
        ),
      );
      h.server.records.add(fleetRecord!.withSeq(7));

      await _pumpSection(tester, service, gate: _gateOffered);
      await tester.pumpAndSettle();
      await _tapVisible(tester, const ValueKey('backup.enrolled.switch'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup.switch.fleet')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('backup.switch.username')),
        'fleet',
      );
      await tester.enterText(
        find.byKey(const ValueKey('backup.switch.password')),
        'pw',
      );
      await tester.enterText(
        find.byKey(const ValueKey('backup.switch.passphrase')),
        'pw',
      );
      await tester.tap(find.byKey(const ValueKey('backup.switch.continue')));
      await _settleRealAsync(tester);

      // The switch holds on the conflict — no bulk resolution.
      expect(
        find.byKey(const ValueKey('backup.switch.conflicts')),
        findsOneWidget,
      );
      final dialog = find.byKey(const ValueKey('backup.switch.dialog'));
      for (final fingerprint in ['SHA256:local', 'SHA256:fleet']) {
        expect(
          find.descendant(of: dialog, matching: find.text(fingerprint)),
          findsOneWidget,
        );
      }
      expect(find.byKey(const ValueKey('backup.switch.close')), findsNothing);
      await tester.tap(
        find.byKey(
          const ValueKey('backup.switch.adoptFleet.conflict.example.com:22'),
        ),
      );
      await _settleRealAsync(tester);
      expect(find.byKey(const ValueKey('backup.switch.done')), findsOneWidget);
      expect(service.pinConflicts, isEmpty);
    });
  });

  testWidgets('captures the §4.3/§4.4 states', (tester) async {
    if (_captureOn) await tester.runAsync(_loadRealFonts);
    tester.view.physicalSize = const Size(760, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = _captureOn ? _captureTheme : null;

    // 1. The unenrolled form with the shared option offered.
    await _pumpSection(tester, h.service, gate: _gateOffered, theme: theme);
    await tester.pumpAndSettle();
    await _capture(tester, '01-enrollment-form');

    // 2. The shared option selected: checkbox + disclosure + fields.
    await tester.tap(find.byKey(const ValueKey('backup.mode.shared')));
    await tester.pumpAndSettle();
    await _capture(tester, '02-shared-option');

    // 3. The enrolled separate surface.
    final enrolled = await h.enrolled();
    await _pumpSection(tester, enrolled, gate: _gateOffered, theme: theme);
    await tester.pumpAndSettle();
    await _capture(tester, '03-enrolled-separate');

    // 4. The paused + conflicted surface.
    final h2 = _Harness();
    h2.state.unverified = true;
    h2.state.raised.add(syncNoticeAccountAuthFailed);
    h2.credentials.vaultKey = List.filled(32, 5);
    await tester.runAsync(h2.seedPinConflict);
    final conflicted = (await tester.runAsync(h2.enrolled))!;
    await _pumpSection(tester, conflicted, theme: theme);
    await tester.pumpAndSettle();
    await _capture(tester, '04-paused-conflict');

    // 5. The switch dialog's confirm phase.
    final h3 = _Harness();
    final switcher = await h3.enrolled();
    await _pumpSection(tester, switcher, gate: _gateOffered, theme: theme);
    await tester.pumpAndSettle();
    await _tapVisible(tester, const ValueKey('backup.enrolled.switch'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      '05-switch-confirm',
      key: const ValueKey('backup.capture'),
    );
  });
}
