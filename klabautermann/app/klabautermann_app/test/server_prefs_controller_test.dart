import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/server_prefs_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

FleetEntry _entry(
  String id, {
  FleetEntryOrigin origin = FleetEntryOrigin.synced,
  bool excluded = false,
}) => FleetEntry(
  serverId: id,
  label: id,
  host: '$id.example.com',
  port: kSshDefaultPort,
  origin: origin,
  excludedFromSync: excluded,
);

void main() {
  late FakeEngineClient engine;
  late ServerPrefsController prefs;

  setUp(() {
    engine = FakeEngineClient();
    prefs = ServerPrefsController(engine);
  });

  tearDown(() async {
    prefs.dispose();
    await engine.close();
  });

  test('synced servers sync their preferences, but not an excluded one or '
      'an import', () async {
    engine.emit(
      CatalogReplaced([
        _entry('srv-1'),
        _entry('srv-2', excluded: true),
        _entry('ssh-config:web', origin: FleetEntryOrigin.sshConfig),
      ]),
    );
    await pumpEventQueue();

    expect(prefs.syncs('srv-1'), isTrue);
    expect(prefs.syncs('srv-2'), isFalse);
    expect(prefs.syncs('ssh-config:web'), isFalse);
  });

  test("a server's record shows, and a removal drops it", () async {
    engine.emit(const ServerPrefsChanged('srv-1', ServerPrefs(readOnly: true)));
    await pumpEventQueue();
    expect(prefs.prefs['srv-1']?.readOnly, isTrue);

    engine.emit(const ServerPrefsChanged('srv-1', null));
    await pumpEventQueue();
    expect(prefs.prefs, isEmpty);
  });

  test('a write completes once written and fails when refused', () async {
    final written = prefs.write('srv-1', const ServerPrefs(marks: {'db'}));
    final request =
        engine.sentOfType<SetServerPrefs>().single as SetServerPrefs;
    expect(request.prefs?.marks, {'db'});
    engine.emit(CatalogWritten(requestId: request.requestId));
    await written;

    final refused = prefs.write('srv-1', null);
    final second = engine.sentOfType<SetServerPrefs>().last as SetServerPrefs;
    expect(second.prefs, isNull);
    engine.emit(
      CatalogWriteRefused(
        requestId: second.requestId,
        failure: CatalogWriteFailure.notEnrolled,
      ),
    );
    await expectLater(
      refused,
      throwsA(
        isA<ServerPrefsNotSavedException>().having(
          (e) => e.failure,
          'failure',
          CatalogWriteFailure.notEnrolled,
        ),
      ),
    );
  });
}
