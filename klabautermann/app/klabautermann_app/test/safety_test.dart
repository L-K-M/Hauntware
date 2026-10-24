// The safety preferences in the app (M4 plan M4, E19a): the controller
// applies every policy to the engine before it saves it, the stored form
// reads leniently toward observe-only, and the server header carries the
// Safety menu with the observe-only and read-only notices.
import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/services/stored_safety.dart';
import 'package:klabautermann_app/ui/server_header.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';

const _observeOnly =
    'Observe only: Klabautermann reads this server and changes nothing. '
    'To act on it, turn on Allow actions in the Safety menu.';
const _readOnly = 'Read-only: actions on this server are hidden.';

void main() {
  group('SafetyController', () {
    late List<SafetyPolicy> applied;
    late List<SafetyPolicy> saved;

    setUp(() {
      applied = [];
      saved = [];
    });

    SafetyController controller({
      SafetyPolicy initial = const SafetyPolicy(),
      bool saveFails = false,
    }) {
      final safety = SafetyController(
        initial: initial,
        apply: applied.add,
        save: (policy) async {
          if (saveFails) throw const FileSystemException('disk full');
          saved.add(policy);
        },
      );
      addTearDown(safety.dispose);
      return safety;
    }

    test('applies the restored policy at once, since the engine starts '
        'observe-only', () {
      controller(initial: const SafetyPolicy(globalReadOnly: true));
      expect(applied.single.globalReadOnly, isTrue);
      expect(saved, isEmpty);
    });

    test('applies each change, then saves it', () async {
      final safety = controller();
      await safety.setServerSafety(
        'srv-1',
        const ServerSafety(management: true),
      );
      await safety.setAdminExpiry(const Duration(minutes: 5));
      await safety.setGlobalReadOnly(true);

      expect(applied, hasLength(4));
      expect(saved, hasLength(3));
      expect(applied.last, same(saved.last));
      expect(safety.value.servers['srv-1']?.management, isTrue);
      expect(safety.value.adminExpiry, const Duration(minutes: 5));
      expect(safety.value.globalReadOnly, isTrue);
    });

    test('a server back at the defaults leaves the policy, and a no-op '
        'change applies nothing', () async {
      final safety = controller(
        initial: const SafetyPolicy(
          servers: {'srv-1': ServerSafety(management: true)},
        ),
      );
      await safety.setServerSafety('srv-1', const ServerSafety());
      expect(safety.value.servers, isEmpty);

      final before = applied.length;
      await safety.setServerSafety('srv-1', const ServerSafety());
      await safety.setGlobalReadOnly(false);
      await safety.setAdminExpiry(kDefaultAdminExpiry);
      expect(applied, hasLength(before));
    });

    test('an expiry the tab does not offer is a caller error', () {
      final safety = controller();
      expect(
        () => safety.setAdminExpiry(const Duration(minutes: 7)),
        throwsArgumentError,
      );
      expect(applied, hasLength(1));
    });

    test('a change it cannot save is still applied and says so', () async {
      final safety = controller(saveFails: true);
      await expectLater(
        safety.setGlobalReadOnly(true),
        throwsA(isA<SafetyNotSavedException>()),
      );
      expect(safety.value.globalReadOnly, isTrue);
      expect(applied.last.globalReadOnly, isTrue);
    });
  });

  group('synced servers (M5 plan M06)', () {
    late List<SafetyPolicy> applied;
    late List<SafetyPolicy> saved;
    late _Prefs prefs;

    setUp(() {
      applied = [];
      saved = [];
      prefs = _Prefs();
    });

    SafetyController controller({
      SafetyPolicy initial = const SafetyPolicy(),
      bool saveFails = false,
    }) {
      final safety = SafetyController(
        initial: initial,
        apply: applied.add,
        save: (policy) async {
          if (saveFails) throw const FileSystemException('disk full');
          saved.add(policy);
        },
        prefs: prefs,
      );
      addTearDown(safety.dispose);
      return safety;
    }

    test("a synced server's switch and marks come from its record, and "
        'management stays on this device', () {
      prefs
        ..syncing.add('srv-1')
        ..records['srv-1'] = const ServerPrefs(readOnly: true, marks: {'db'});
      final safety = controller(
        initial: const SafetyPolicy(
          servers: {'srv-1': ServerSafety(management: true)},
        ),
      );

      final merged = safety.value.servers['srv-1']!;
      expect((merged.management, merged.readOnly), (true, true));
      expect(merged.marks, {'db'});
      expect(applied.last.servers['srv-1']!.readOnly, isTrue);
    });

    test('a change writes the record, applied before the write answers, '
        'and keeps only management here', () async {
      prefs.syncing.add('srv-1');
      final safety = controller();
      final gate = prefs.gate = Completer<void>();

      final change = safety.setServerSafety(
        'srv-1',
        const ServerSafety(management: true, readOnly: true, marks: {'db'}),
      );
      await pumpEventQueue();
      expect(applied.last.servers['srv-1']!.readOnly, isTrue);
      final (id, written) = prefs.writes.single;
      expect((id, written?.readOnly), ('srv-1', true));
      expect(written?.marks, {'db'});

      gate.complete();
      await change;
      final stored = saved.last.servers['srv-1']!;
      expect((stored.management, stored.readOnly), (true, false));
      expect(stored.marks, isEmpty);
      expect(safety.value.servers['srv-1']!.readOnly, isTrue);
    });

    test('a refused write says so, and the record counts again', () async {
      prefs
        ..syncing.add('srv-1')
        ..refuse = StateError('refused');
      final safety = controller();

      await expectLater(
        safety.setServerSafety('srv-1', const ServerSafety(readOnly: true)),
        throwsA(isA<SafetyNotSavedException>()),
      );
      expect(safety.value.servers['srv-1'], isNull);
      expect(applied.last.servers['srv-1'], isNull);
    });

    test('a switch and marks stored here move to the record once, merged, '
        'and count meanwhile', () async {
      prefs
        ..syncing.add('srv-1')
        ..records['srv-1'] = const ServerPrefs(marks: {'b'});
      final gate = prefs.gate = Completer<void>();
      final safety = controller(
        initial: const SafetyPolicy(
          servers: {
            'srv-1': ServerSafety(readOnly: true, marks: {'a'}),
          },
        ),
      );

      // The engine never enforces less than either holds.
      expect(applied.last.servers['srv-1']!.readOnly, isTrue);
      expect(applied.last.servers['srv-1']!.marks, {'a', 'b'});
      final (_, written) = prefs.writes.single;
      expect(written?.readOnly, isTrue);
      expect(written?.marks, {'a', 'b'});

      gate.complete();
      await pumpEventQueue();
      expect(saved.last.servers, isEmpty);
      expect(safety.value.servers['srv-1']!.marks, {'a', 'b'});
      expect(prefs.writes, hasLength(1));
    });

    test('review fix: an earlier write answering keeps a later one '
        'counting', () async {
      prefs.syncing.add('srv-1');
      final safety = controller();
      final first = prefs.gate = Completer<void>();
      final marking = safety.setServerSafety(
        'srv-1',
        const ServerSafety(marks: {'db'}),
      );
      await pumpEventQueue();
      final second = prefs.gate = Completer<void>();
      final locking = safety.setServerSafety(
        'srv-1',
        const ServerSafety(readOnly: true, marks: {'db'}),
      );
      await pumpEventQueue();

      first.complete();
      await marking;
      expect(applied.last.servers['srv-1']!.readOnly, isTrue);

      second.complete();
      await locking;
      expect(applied.last.servers['srv-1']!.readOnly, isTrue);
    });

    test('review fix: a refused write keeps a later reset counting', () async {
      prefs
        ..syncing.add('srv-1')
        ..records['srv-1'] = const ServerPrefs(readOnly: true);
      final safety = controller();
      final first = prefs.gate = Completer<void>();
      final clearing = safety.setServerSafety('srv-1', const ServerSafety());
      await pumpEventQueue();
      final second = prefs.gate = Completer<void>();
      final again = safety.setServerSafety('srv-1', const ServerSafety());
      await pumpEventQueue();

      prefs.refuse = StateError('refused');
      first.complete();
      await expectLater(clearing, throwsA(isA<SafetyNotSavedException>()));
      prefs.refuse = null;
      expect(applied.last.servers['srv-1'], isNull);

      second.complete();
      await again;
      expect(safety.value.servers['srv-1'], isNull);
    });

    test('review fix: a server that stops syncing during a write keeps the '
        'written switch here', () async {
      prefs.syncing.add('srv-1');
      final safety = controller();
      final gate = prefs.gate = Completer<void>();
      final change = safety.setServerSafety(
        'srv-1',
        const ServerSafety(readOnly: true, marks: {'db'}),
      );
      await pumpEventQueue();

      prefs.syncing.clear();
      gate.complete();
      await change;

      final kept = saved.last.servers['srv-1']!;
      expect(kept.readOnly, isTrue);
      expect(kept.marks, {'db'});
      expect(safety.value.servers['srv-1']!.readOnly, isTrue);
    });

    test('review fix: a refused write still observes a failed management '
        'save', () async {
      prefs
        ..syncing.add('srv-1')
        ..refuse = StateError('refused');
      final safety = controller(saveFails: true);

      await expectLater(
        safety.setServerSafety(
          'srv-1',
          const ServerSafety(management: true, readOnly: true),
        ),
        throwsA(isA<SafetyNotSavedException>()),
      );
      await pumpEventQueue();
    });

    test(
      'review fix: a write answering after dispose notifies no one',
      () async {
        prefs.syncing.add('srv-1');
        final safety = SafetyController(
          initial: const SafetyPolicy(),
          apply: applied.add,
          save: (policy) async => saved.add(policy),
          prefs: prefs,
        );
        final gate = prefs.gate = Completer<void>();
        final change = safety.setServerSafety(
          'srv-1',
          const ServerSafety(readOnly: true),
        );
        await pumpEventQueue();

        safety.dispose();
        gate.complete();
        await change;
      },
    );

    test('a server that stops syncing keeps its switch and marks here', () {
      prefs
        ..syncing.add('srv-1')
        ..records['srv-1'] = const ServerPrefs(readOnly: true, marks: {'db'});
      final safety = controller();

      prefs.syncing.clear();
      prefs.notifyListeners();

      final kept = saved.last.servers['srv-1']!;
      expect(kept.readOnly, isTrue);
      expect(kept.marks, {'db'});
      expect(safety.value.servers['srv-1']!.readOnly, isTrue);
    });
  });

  group('the stored form', () {
    test('round-trips, marks sorted', () {
      const policy = SafetyPolicy(
        globalReadOnly: true,
        adminExpiry: Duration(minutes: 30),
        servers: {
          'srv-1': ServerSafety(
            management: true,
            readOnly: true,
            marks: {'web-1', 'db-1'},
          ),
        },
      );
      final json = encodeStoredSafety(policy);
      expect((json['servers']! as Map)['srv-1'], {
        'management': true,
        'readOnly': true,
        'marks': ['db-1', 'web-1'],
      });
      final back = decodeStoredSafety(json);
      expect(back.globalReadOnly, isTrue);
      expect(back.adminExpiry, const Duration(minutes: 30));
      expect(back.servers['srv-1']?.marks, {'web-1', 'db-1'});
      expect(back.servers['srv-1']?.readOnly, isTrue);
    });

    test('anything unreadable reads as the safe default', () {
      final none = decodeStoredSafety(null);
      expect(none.globalReadOnly, isFalse);
      expect(none.servers, isEmpty);
      expect(none.adminExpiry, kDefaultAdminExpiry);

      final damaged = decodeStoredSafety({
        'globalReadOnly': 'yes',
        'adminExpiryMinutes': 7,
        'servers': {
          'srv-1': {'management': 'true', 'marks': 'web-1'},
          'srv-2': 'on',
          'srv-3': {
            'management': true,
            'marks': ['web-1', 3],
          },
          'srv-4': {'management': true, 'readOnly': 'yes'},
        },
      });
      // A read-only switch that does not read as off never grants
      // actions back: the file can only take them away.
      expect(damaged.globalReadOnly, isTrue);
      expect(damaged.servers['srv-4']?.management, isFalse);
      expect(damaged.adminExpiry, kDefaultAdminExpiry);
      expect(damaged.servers['srv-1']?.management, isFalse);
      expect(damaged.servers['srv-1']?.marks, isEmpty);
      expect(damaged.servers.containsKey('srv-2'), isFalse);
      expect(damaged.servers['srv-3']?.marks, {'web-1'});
    });
  });

  group('the server header', () {
    Future<SafetyController> openWeb1(
      WidgetTester tester, {
      SafetyPolicy initial = const SafetyPolicy(),
    }) async {
      final safety = SafetyController(initial: initial, apply: (_) {});
      addTearDown(safety.dispose);
      await pumpApp(tester, servers: twoServers, safety: safety);
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      return safety;
    }

    Finder inHeader(Finder finder) =>
        find.descendant(of: find.byType(ServerHeader), matching: finder);

    testWidgets('says a server is observe-only until actions are allowed in '
        'its Safety menu (03 §4.3 step 5)', (tester) async {
      final safety = await openWeb1(tester);
      expect(inHeader(find.text(_observeOnly)), findsOneWidget);
      expect(inHeader(find.text(_readOnly)), findsNothing);

      await tester.tap(inHeader(find.byTooltip('Safety')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow actions'));
      await tester.pumpAndSettle();

      expect(safety.value.servers['srv-1']?.management, isTrue);
      expect(inHeader(find.text(_observeOnly)), findsNothing);
    });

    testWidgets('says a server is read-only, by its own switch or the '
        'global one', (tester) async {
      final safety = await openWeb1(
        tester,
        initial: const SafetyPolicy(
          servers: {'srv-1': ServerSafety(management: true)},
        ),
      );
      expect(inHeader(find.text(_readOnly)), findsNothing);

      await tester.tap(inHeader(find.byTooltip('Safety')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read-only'));
      await tester.pumpAndSettle();
      expect(safety.value.servers['srv-1']?.readOnly, isTrue);
      expect(inHeader(find.text(_readOnly)), findsOneWidget);

      await safety.setServerSafety(
        'srv-1',
        const ServerSafety(management: true),
      );
      await safety.setGlobalReadOnly(true);
      await tester.pumpAndSettle();
      expect(inHeader(find.text(_readOnly)), findsOneWidget);
    });

    testWidgets('without safety preferences there is no Safety menu', (
      tester,
    ) async {
      await pumpApp(tester, servers: twoServers);
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      expect(inHeader(find.byTooltip('Safety')), findsNothing);
      expect(inHeader(find.text(_observeOnly)), findsNothing);
    });
  });
}

/// The synced side as a test drives it: which servers sync, their
/// records, and every write, which [gate] can hold and [refuse] fail.
final class _Prefs extends ChangeNotifier implements ServerPrefsSource {
  final syncing = <String>{};
  final records = <String, ServerPrefs>{};
  final writes = <(String, ServerPrefs?)>[];
  Completer<void>? gate;
  Object? refuse;

  @override
  bool syncs(String serverId) => syncing.contains(serverId);

  @override
  Map<String, ServerPrefs> get prefs => Map.unmodifiable(records);

  @override
  Future<void> write(String serverId, ServerPrefs? prefs) async {
    writes.add((serverId, prefs));
    // Each write waits on the gate set when it started.
    if (gate case final gate?) await gate.future;
    if (refuse case final error?) throw error;
    if (prefs == null) {
      records.remove(serverId);
    } else {
      records[serverId] = prefs;
    }
    notifyListeners();
  }

  @override
  void notifyListeners() => super.notifyListeners();
}
