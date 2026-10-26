import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/shell_location.dart';
import 'package:seance_core/seance_core.dart';

/// TrueNAS's zsh sets a prompt and nothing else: no OSC 7, no title. Its
/// directory is read beside it instead, once for the Files and Git panes
/// and the tab alike.
void main() {
  late ValueNotifier<String?> osc7;
  late ValueNotifier<String?> title;
  late ValueNotifier<int> moved;

  /// What each read answers, in order: a directory, null for no answer, or
  /// a [RemoteCommandResult] (or a future of one) as the server sends.
  late List<Object?> answers;
  late int reads;
  late int announcements;

  setUp(() {
    osc7 = ValueNotifier<String?>(null);
    title = ValueNotifier<String?>(null);
    moved = ValueNotifier<int>(0);
    answers = [];
    reads = 0;
    announcements = 0;
  });

  tearDown(() {
    osc7.dispose();
    title.dispose();
    moved.dispose();
  });

  RemoteShellDirectory reader() =>
      RemoteShellDirectory((command, {timeout}) async {
        reads++;
        final answer = answers.isEmpty ? null : answers.removeAt(0);
        return switch (answer) {
          final Future<RemoteCommandResult> later => await later,
          final RemoteCommandResult result => result,
          final String path => _answer(path),
          _ => const RemoteCommandResult(exitCode: 4),
        };
      });

  ShellLocation location({bool reading = true}) {
    final location = ShellLocation(
      reported: osc7,
      mayHaveMoved: moved,
      titleChanged: title,
    )..addListener(() => announcements++);
    addTearDown(location.dispose);
    if (reading) location.readWith(reader());
    return location;
  }

  /// Past the debounce after a cue.
  const settle = Duration(seconds: 1);

  test('reads at once, then after each Enter', () {
    fakeAsync((async) {
      answers = ['/var/log', '/home/test/docker'];
      final shell = location();
      async.flushMicrotasks();
      expect(shell.value, '/var/log');

      moved.value++;
      async.elapse(settle);
      expect(shell.value, '/home/test/docker');
      expect(reads, 2);
      expect(announcements, 2);
    });
  });

  test('a burst of Enters reads once', () {
    fakeAsync((async) {
      answers = ['/home/test', '/var/log'];
      final shell = location();
      async.flushMicrotasks();

      for (var i = 0; i < 5; i++) {
        moved.value++;
        async.elapse(const Duration(milliseconds: 50));
      }
      async.elapse(settle);
      expect(shell.value, '/var/log');
      expect(reads, 2);
    });
  });

  test('an unchanged answer is not announced', () {
    fakeAsync((async) {
      answers = ['/var/log', '/var/log'];
      location();
      async.flushMicrotasks();

      moved.value++;
      async.elapse(settle);
      expect(reads, 2);
      expect(announcements, 1);
    });
  });

  test('no answer keeps the last directory', () {
    fakeAsync((async) {
      answers = ['/var/log', null];
      final shell = location();
      async.flushMicrotasks();

      moved.value++;
      async.elapse(settle);
      expect(reads, 2);
      expect(shell.value, '/var/log');
    });
  });

  test('asks again shortly until the shell first answers', () {
    fakeAsync((async) {
      // Read at connect, before sshd has started the shell.
      answers = [null, '/home/test'];
      final shell = location();
      async.flushMicrotasks();
      expect(shell.value, isNull);

      async.elapse(settle);
      expect(reads, 2);
      expect(shell.value, '/home/test');

      async.elapse(const Duration(seconds: 10));
      expect(reads, 2);
    });
  });

  test('stops asking again after a few unanswered reads', () {
    fakeAsync((async) {
      location();
      async.elapse(const Duration(seconds: 10));
      expect(reads, 3);

      moved.value++;
      async.elapse(settle);
      expect(reads, 4, reason: 'an Enter still asks');
    });
  });

  test('a title change is a cue to read again', () {
    fakeAsync((async) {
      // `git clone … && cd repo`: the cd lands after the read that followed
      // its Enter, and only the title says so.
      answers = ['/home/test', '/home/test/repo'];
      final shell = location();
      async.flushMicrotasks();

      title.value = 'root@server: ~/repo';
      async.elapse(settle);
      expect(shell.value, '/home/test/repo');
    });
  });

  test('reads nothing while OSC 7 answers, which outranks a read', () {
    fakeAsync((async) {
      answers = ['/var/log'];
      final shell = location();
      async.flushMicrotasks();

      osc7.value = '/srv';
      expect(shell.value, '/srv');
      expect(announcements, 2);

      moved.value++;
      title.value = 'root@server: /tmp';
      async.elapse(settle);
      expect(reads, 1);
    });
  });

  test('once the server cannot answer, the read is dropped for good', () {
    fakeAsync((async) {
      answers = ['/var/log', const RemoteCommandResult(exitCode: 3)];
      final shell = location();
      async.flushMicrotasks();

      moved.value++;
      async.elapse(settle);
      expect(shell.value, isNull);
      expect(announcements, 2);

      moved.value++;
      async.elapse(settle);
      expect(reads, 2);
    });
  });

  test('reads one at a time, and once more for an Enter meanwhile', () {
    fakeAsync((async) {
      final slow = Completer<RemoteCommandResult>();
      answers = [slow.future, '/var/log'];
      final shell = location();
      async.flushMicrotasks();

      moved.value++;
      async.elapse(settle);
      moved.value++;
      async.elapse(settle);
      expect(reads, 1, reason: 'no second read while one is in flight');

      slow.complete(_answer('/home/test'));
      async.flushMicrotasks();
      expect(reads, 2);
      expect(shell.value, '/var/log');
    });
  });

  test('stops reading with the connection, keeping the last answer', () {
    fakeAsync((async) {
      final slow = Completer<RemoteCommandResult>();
      answers = ['/var/log', slow.future];
      final shell = location();
      async.flushMicrotasks();
      moved.value++;
      async.elapse(settle);
      expect(reads, 2);

      shell.stopReading();
      slow.complete(_answer('/home/test'));
      moved.value++;
      async.elapse(settle);
      expect(reads, 2);
      expect(shell.value, '/var/log');
    });
  });

  test('readNow reads nothing while OSC 7 answers', () {
    fakeAsync((async) {
      answers = [Completer<RemoteCommandResult>().future];
      final shell = location();
      async.flushMicrotasks();
      osc7.value = '/srv';

      var answered = false;
      unawaited(shell.readNow().then((_) => answered = true));
      async.flushMicrotasks();
      expect(answered, isTrue);
      expect(reads, 1);
    });
  });

  test('readNow joins the read in flight', () {
    fakeAsync((async) {
      final slow = Completer<RemoteCommandResult>();
      answers = [slow.future];
      final shell = location();
      var answered = false;
      unawaited(shell.readNow().then((_) => answered = true));
      async.flushMicrotasks();
      expect(answered, isFalse);

      slow.complete(_answer('/var/log'));
      async.flushMicrotasks();
      expect(answered, isTrue);
      expect(shell.value, '/var/log');
      expect(reads, 1);
    });
  });

  test('readNow reads at once when none is in flight', () {
    fakeAsync((async) {
      answers = ['/home/test', '/var/log'];
      final shell = location();
      async.flushMicrotasks();

      unawaited(shell.readNow());
      async.flushMicrotasks();
      expect(reads, 2);
      expect(shell.value, '/var/log');
    });
  });

  test('without a reader it is OSC 7 alone', () {
    fakeAsync((async) {
      final shell = location(reading: false);
      moved.value++;
      async.elapse(settle);
      expect(shell.value, isNull);
      expect(reads, 0);

      osc7.value = '/srv';
      expect(shell.value, '/srv');
      expect(announcements, 1);
    });
  });

  test('an answer arriving after dispose is dropped quietly', () {
    fakeAsync((async) {
      final slow = Completer<RemoteCommandResult>();
      answers = [slow.future];
      final shell = ShellLocation(reported: osc7, mayHaveMoved: moved)
        ..addListener(() => announcements++)
        ..readWith(reader());
      async.flushMicrotasks();

      shell.dispose();
      slow.complete(_answer('/var/log'));
      moved.value++;
      async.elapse(settle);
      expect(announcements, 0);
      expect(reads, 1);
    });
  });
}

/// What [RemoteShellDirectory]'s script prints when the shell is in [path].
RemoteCommandResult _answer(String path) =>
    RemoteCommandResult(stdout: 'seance-cwd\n$path\n', exitCode: 0);
