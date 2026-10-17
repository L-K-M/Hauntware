/// Shared scaffolding for the wire-level tests: a scripted daemon end on
/// a [FakeDuplexPair] that records every byte the client wrote and lets
/// the test feed response bytes in arbitrary chunkings.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_docker/testing.dart';
import 'package:test/test.dart';

/// This package's root, resolved from the package URI so fixture reads work
/// whether the suite runs from `klabautermann/` or the package directory.
final String _packageRoot = () {
  final uri = Isolate.resolvePackageUriSync(
    Uri.parse('package:klabautermann_docker/klabautermann_docker.dart'),
  );
  if (uri == null) {
    throw StateError('could not resolve the klabautermann_docker package URI');
  }
  return File.fromUri(uri).parent.parent.path;
}();

/// Reads a hand-written fixture (03 §11.3) from `test/fixtures`.
List<int> fixtureBytes(String name) =>
    File('$_packageRoot/test/fixtures/$name').readAsBytesSync();

/// Reads a hand-written fixture (03 §11.3) as text from `test/fixtures`.
String fixtureString(String name) =>
    File('$_packageRoot/test/fixtures/$name').readAsStringSync();

/// The fixtures directory, `test/fixtures`.
Directory get fixturesDirectory => Directory('$_packageRoot/test/fixtures');

/// The scripted server side of a [FakeDuplexPair]. `pair.client` goes to
/// the code under test; this object plays the daemon: it records the
/// request bytes, feeds response bytes, and half-closes.
final class FakeDaemon {
  FakeDaemon() {
    pair.server.stream.listen(
      (c) {
        received.addAll(c);
        for (final w in List.of(_waiters)) {
          if (received.length >= w.$1) {
            _waiters.remove(w);
            w.$2.complete();
          }
        }
        for (final w in List.of(_textWaiters)) {
          if (text.contains(w.$1)) {
            _textWaiters.remove(w);
            w.$2.complete();
          }
        }
      },
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
    );
  }

  final FakeDuplexPair pair = FakeDuplexPair();

  /// Every byte the client wrote, concatenated.
  final List<int> received = <int>[];

  /// Completes when the client end is fully closed.
  final Completer<void> closed = Completer<void>();

  final List<(int, Completer<void>)> _waiters = <(int, Completer<void>)>[];
  final List<(String, Completer<void>)> _textWaiters =
      <(String, Completer<void>)>[];

  /// The request bytes decoded as Latin-1 (HTTP heads are ASCII; bodies
  /// are checked through [received] instead).
  String get text => latin1.decode(received);

  /// Feeds [bytes] to the client as one inbound chunk.
  void feed(List<int> bytes) => pair.server.sink.add(bytes);

  /// Feeds [bytes] as several inbound chunks in order.
  void feedChunks(List<List<int>> chunks) {
    for (final c in chunks) {
      pair.server.sink.add(c);
    }
  }

  /// Server-side EOF on the response direction only: the client sees the
  /// inbound stream end while its writes still arrive. Models a
  /// close-delimited response end.
  Future<void> eof() => pair.server.closeWrite();

  /// Full close of both directions.
  Future<void> hangup() => pair.server.close();

  /// Waits until at least [n] request bytes have arrived.
  Future<void> gotBytes(int n) {
    if (received.length >= n) return Future<void>.value();
    final c = Completer<void>();
    _waiters.add((n, c));
    return c.future;
  }

  /// Waits until the accumulated request text contains [needle]. Robust to
  /// a pooled connection being handed off before the caller resumes.
  Future<void> gotText(String needle) {
    if (text.contains(needle)) return Future<void>.value();
    final c = Completer<void>();
    _textWaiters.add((needle, c));
    return c.future;
  }
}

/// Encodes an HTTP response head plus optional body as wire bytes.
List<int> wireResponse(
  String status, {
  Map<String, String>? headers,
  List<int>? body,
}) {
  final b = StringBuffer('HTTP/1.1 $status\r\n');
  headers?.forEach((k, v) => b.write('$k: $v\r\n'));
  b.write('\r\n');
  final out = BytesBuilder()..add(latin1.encode(b.toString()));
  if (body != null) out.add(body);
  return out.takeBytes();
}

/// Runs a request through a fresh [DockerHttpClient] bound to a fresh
/// [FakeDaemon] for every two-chunk split of [wire], then once more fed
/// one byte at a time (03 §5.5: robust to every chunk boundary). [check]
/// receives the send result. When [eof] is set the daemon half-closes
/// after the bytes, for close-delimited responses.
Future<void> forEverySplit<T>(
  List<int> wire,
  Future<T> Function(DockerHttpClient client) start,
  FutureOr<void> Function(T result) check, {
  bool eof = false,
}) async {
  Future<void> run(List<List<int>> chunks) async {
    final daemon = FakeDaemon();
    final client = DockerHttpClient(() async => daemon.pair.client);
    final result = start(client);
    daemon.feedChunks(chunks);
    if (eof) unawaited(daemon.eof());
    await check(await result);
  }

  for (var i = 0; i <= wire.length; i++) {
    await run([wire.sublist(0, i), wire.sublist(i)]);
  }
  await run([for (var i = 0; i < wire.length; i++) wire.sublist(i, i + 1)]);
}

/// Expects [future] to complete with an exception that is a [T].
Future<T> expectThrows<T extends Object>(Future<Object?> future) async {
  try {
    await future;
  } on T catch (e) {
    return e;
  } catch (e) {
    fail('expected $T, got ${e.runtimeType}: $e');
  }
  fail('expected $T, but nothing was thrown');
}

List<int> utf8Of(String s) => utf8.encode(s);
