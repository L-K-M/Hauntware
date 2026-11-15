import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';

/// `window_state.json` as [GhostWindowStateFile] reads and writes it. The
/// hosts' own atomic writers are tested with their settings files.
void main() {
  late Directory directory;
  late File file;

  Future<void> plainWrite(File target, Map<String, dynamic> json) =>
      target.writeAsString(jsonEncode(json));

  GhostWindowStateFile stateFile({GhostWindowStateWriter? write}) =>
      GhostWindowStateFile(file, write: write ?? plainWrite);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ghost_window_state');
    file = File('${directory.path}${Platform.pathSeparator}window_state.json');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  const first = GhostWindowSnapshot(bounds: Rect.fromLTWH(0, 0, 400, 300));
  const second = GhostWindowSnapshot(bounds: Rect.fromLTWH(50, 60, 900, 700));

  test('a missing file loads as nothing saved', () async {
    expect(await stateFile().load(), isNull);
  });

  test('round-trips a snapshot in the shared schema', () async {
    const snapshot = GhostWindowSnapshot(
      bounds: Rect.fromLTWH(10, 20, 1000, 700),
      isFullScreen: true,
    );
    await stateFile().save(snapshot);

    expect(jsonDecode(await file.readAsString()), {
      'x': 10.0,
      'y': 20.0,
      'width': 1000.0,
      'height': 700.0,
      'isMaximized': false,
      'isFullScreen': true,
    });
    expect(await stateFile().load(), snapshot);
  });

  test('a window_state.json from an earlier release still loads', () async {
    await file.writeAsString(
      '{"x":10.0,"y":20.0,"width":1000.0,"height":700.0,'
      '"isMaximized":false,"isFullScreen":true}',
    );

    expect(
      await stateFile().load(),
      const GhostWindowSnapshot(
        bounds: Rect.fromLTWH(10, 20, 1000, 700),
        isFullScreen: true,
      ),
    );
  });

  test('flags without a frame persist on their own', () async {
    const snapshot = GhostWindowSnapshot(isMaximized: true);
    await stateFile().save(snapshot);
    expect(await stateFile().load(), snapshot);
  });

  test('a file that is not a snapshot loads as nothing saved', () async {
    for (final text in ['not json', '{not json', '[]', '"x"', '']) {
      await file.writeAsString(text);
      expect(await stateFile().load(), isNull, reason: text);
    }
  });

  test('drops an unusable frame but keeps the flags', () async {
    await file.writeAsString(
      jsonEncode({
        'x': 'soon',
        'y': 0,
        'width': -5,
        'height': 10,
        'isFullScreen': true,
      }),
    );

    expect(
      await stateFile().load(),
      const GhostWindowSnapshot(isFullScreen: true),
    );
  });

  test('a later save overwrites a malformed file', () async {
    await file.writeAsString('this is not json');
    await stateFile().save(second);
    expect(await stateFile().load(), second);
  });

  test('passes the snapshot to the host writer as JSON', () async {
    final written = <Map<String, dynamic>>[];
    await stateFile(
      write: (target, json) async {
        expect(target.path, file.path);
        written.add(json);
      },
    ).save(second);

    expect(written, [second.toJson()]);
  });

  test('writes one save at a time, in the order asked', () async {
    final events = <String>[];
    final firstWrite = Completer<void>();
    var writes = 0;
    final windowState = stateFile(
      write: (target, json) async {
        final name = ++writes == 1 ? 'first' : 'second';
        events.add('$name started');
        if (name == 'first') await firstWrite.future;
        events.add('$name done');
      },
    );

    final saves = Future.wait([
      windowState.save(first),
      windowState.save(second),
    ]);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(events, ['first started'], reason: 'the second save waits');

    firstWrite.complete();
    await saves;
    expect(events, [
      'first started',
      'first done',
      'second started',
      'second done',
    ]);
  });

  test('queued saves land last-writer-wins', () async {
    final windowState = stateFile();
    await Future.wait([windowState.save(first), windowState.save(second)]);
    expect(await stateFile().load(), second);
  });

  test('a failed save reports its error and does not hold up the next '
      'one', () async {
    final written = <Map<String, dynamic>>[];
    var writes = 0;
    final windowState = stateFile(
      write: (target, json) async {
        if (++writes == 1) throw const FileSystemException('disk full');
        written.add(json);
      },
    );

    final failed = windowState.save(first);
    final next = windowState.save(second);

    await expectLater(failed, throwsA(isA<FileSystemException>()));
    await next;
    expect(written, [second.toJson()]);
  });
}
