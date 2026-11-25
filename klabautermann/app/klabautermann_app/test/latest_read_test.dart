import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/latest_read.dart';

/// A stand-in State: it counts notifications and can go away.
class _Owner {
  int notifications = 0;
  bool isMounted = true;

  void setState(VoidCallback fn) {
    notifications++;
    fn();
  }

  bool mounted() => isMounted;
}

void main() {
  late _Owner owner;
  late LatestRead<String> latest;

  setUp(() {
    owner = _Owner();
    latest = LatestRead(setState: owner.setState, mounted: owner.mounted);
  });

  test('the newest run wins', () async {
    await latest.run(() async => 'first');
    expect(latest.value, 'first');
    expect(latest.reading, isFalse);

    await latest.run(() async => 'second');
    expect(latest.value, 'second');
    expect(latest.reading, isFalse);
  });

  test('an older result arriving late is dropped', () async {
    final older = Completer<String>();
    final newer = Completer<String>();
    unawaited(latest.run(() => older.future));
    unawaited(latest.run(() => newer.future));
    expect(latest.reading, isTrue);

    older.complete('old');
    await Future<void>.delayed(Duration.zero);
    expect(latest.value, isNull);
    expect(latest.reading, isTrue);

    newer.complete('new');
    await Future<void>.delayed(Duration.zero);
    expect(latest.value, 'new');
    expect(latest.reading, isFalse);
  });

  test('an unmounted owner ignores the result', () async {
    final pending = Completer<String>();
    unawaited(latest.run(() => pending.future));
    expect(owner.notifications, 1);

    owner.isMounted = false;
    pending.complete('too late');
    await Future<void>.delayed(Duration.zero);

    expect(latest.value, isNull);
    expect(owner.notifications, 1);
  });

  test('a throwing read clears reading', () async {
    final failed = latest.run(() async => throw StateError('boom'));
    expect(latest.reading, isTrue);

    await expectLater(failed, throwsStateError);
    expect(latest.reading, isFalse);
    expect(latest.value, isNull);
  });

  test('reset forgets the answer and drops a read still out', () async {
    final pending = Completer<String>();
    unawaited(latest.run(() async => 'kept'));
    await Future<void>.delayed(Duration.zero);
    expect(latest.value, 'kept');

    latest.reset();
    expect(latest.value, isNull);

    unawaited(latest.run(() => pending.future));
    latest.reset();
    pending.complete('stale');
    await Future<void>.delayed(Duration.zero);
    expect(latest.value, isNull);
    expect(latest.reading, isFalse);
  });
}
