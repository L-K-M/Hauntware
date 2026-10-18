// The safety preferences in the app (M4 plan M4, E19a): the controller
// applies every policy to the engine before it saves it, the stored form
// reads leniently toward observe-only, and the server header carries the
// Safety menu with the observe-only and read-only notices.
import 'dart:io' show FileSystemException;

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
        },
      });
      expect(damaged.globalReadOnly, isFalse);
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
