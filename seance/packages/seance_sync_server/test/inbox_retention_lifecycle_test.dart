import 'dart:async';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 12);
  SyncServer server(_PurgeStorage storage) => SyncServer(
    storage: storage,
    settings: const ServerSettings(bindAddress: '127.0.0.1', port: 0),
    now: () => now,
  );

  test('purges expired inbox items before listening', () async {
    final storage = _PurgeStorage();
    final timers = _ManualTimers();
    final purgeStarted = Completer<void>();
    final allowPurge = Completer<void>();
    storage.onPurge = (call) async {
      if (call == 1) {
        purgeStarted.complete();
        await allowPurge.future;
      }
      return 0;
    };

    var startCompleted = false;
    final start = server(storage).start(timerFactory: timers.create).then((
      running,
    ) {
      startCompleted = true;
      return running;
    });
    await purgeStarted.future;

    expect(startCompleted, isFalse);
    expect(timers.created, isEmpty);

    allowPurge.complete();
    final running = await start;
    addTearDown(running.close);

    expect(storage.purgeCalls, 1);
    expect(
      storage.storedBefore.single,
      now.subtract(kInboxRetention).millisecondsSinceEpoch + 1,
    );
    expect(timers.active, hasLength(1));
    expect(timers.active.single.duration, const Duration(hours: 1));
  });

  test('periodic purge never overlaps and retries after failure', () async {
    final storage = _PurgeStorage();
    final timers = _ManualTimers();
    final secondPurgeStarted = Completer<void>();
    final allowSecondPurge = Completer<void>();
    storage.onPurge = (call) async {
      if (call == 2) {
        secondPurgeStarted.complete();
        await allowSecondPurge.future;
      }
      if (call == 3) throw StateError('transient purge failure');
      return 0;
    };
    final running = await server(storage).start(timerFactory: timers.create);
    addTearDown(running.close);

    timers.active.single.fire();
    await secondPurgeStarted.future;

    expect(storage.purgeCalls, 2);
    expect(timers.active, isEmpty);

    allowSecondPurge.complete();
    await _settle();
    expect(timers.active, hasLength(1));

    timers.active.single.fire();
    await _settle();
    expect(storage.purgeCalls, 3);
    expect(timers.active, hasLength(1));

    timers.active.single.fire();
    await _settle();
    expect(storage.purgeCalls, 4);
  });

  test('startup purge failure prevents listening and scheduling', () async {
    final storage = _PurgeStorage()
      ..onPurge = (_) => Future<int>.error(StateError('storage unavailable'));
    final timers = _ManualTimers();

    await expectLater(
      server(storage).start(timerFactory: timers.create),
      throwsStateError,
    );

    expect(storage.purgeCalls, 1);
    expect(timers.created, isEmpty);
  });

  test('close cancels a pending purge timer', () async {
    final storage = _PurgeStorage();
    final timers = _ManualTimers();
    final running = await server(storage).start(timerFactory: timers.create);
    final pending = timers.active.single;

    await running.close();
    await running.close();
    pending.fire();
    await _settle();

    expect(pending.isActive, isFalse);
    expect(storage.purgeCalls, 1);
  });

  test('close cancels the timer and waits for an in-flight purge', () async {
    final storage = _PurgeStorage();
    final timers = _ManualTimers();
    final purgeStarted = Completer<void>();
    final allowPurge = Completer<void>();
    storage.onPurge = (call) async {
      if (call == 2) {
        purgeStarted.complete();
        await allowPurge.future;
      }
      return 0;
    };
    final running = await server(storage).start(timerFactory: timers.create);

    timers.active.single.fire();
    await purgeStarted.future;
    var closeCompleted = false;
    final close = running.close().then((_) => closeCompleted = true);
    await _settle();

    expect(closeCompleted, isFalse);
    expect(timers.active, isEmpty);

    allowPurge.complete();
    await close;
    expect(closeCompleted, isTrue);
    expect(timers.active, isEmpty);
  });
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _PurgeStorage extends InMemoryStorage {
  int purgeCalls = 0;
  final List<int> storedBefore = [];
  Future<int> Function(int call)? onPurge;

  @override
  Future<int> purgeInboxItems({required int storedBefore}) {
    purgeCalls++;
    this.storedBefore.add(storedBefore);
    return onPurge?.call(purgeCalls) ?? Future<int>.value(0);
  }
}

class _ManualTimers {
  final List<_ManualTimer> created = [];

  Iterable<_ManualTimer> get active => created.where((timer) => timer.isActive);

  Timer create(Duration duration, void Function() callback) {
    final timer = _ManualTimer(duration, callback);
    created.add(timer);
    return timer;
  }
}

class _ManualTimer implements Timer {
  final Duration duration;
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  _ManualTimer(this.duration, this._callback);

  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    _callback();
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;
}
