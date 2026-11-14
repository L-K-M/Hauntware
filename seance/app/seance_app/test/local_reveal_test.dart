import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:seance_app/services/local_reveal.dart';

void main() {
  late Directory folder;
  late String file;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('seance-reveal-');
    file = '${folder.path}/notes.txt';
    await File(file).writeAsString('x');
  });

  tearDown(() => folder.delete(recursive: true));

  LocalFileReveal reveal({
    GhostRevealProcessResult? Function(String executable)? answer,
    List<String>? launched,
  }) => LocalFileReveal(
    GhostFileRevealer(
      operatingSystem: 'linux',
      run: (executable, arguments, {timeout}) async {
        launched?.add(executable);
        return answer == null ? (exitCode: 0, stderr: '') : answer(executable);
      },
    ),
  );

  test('an existing file goes to the shared revealer', () async {
    final launched = <String>[];
    await reveal(launched: launched).reveal(file);
    expect(launched, ['dbus-send']);
  });

  test('a relative path never reaches a process', () async {
    final launched = <String>[];
    await expectLater(
      reveal(launched: launched).reveal('notes.txt'),
      throwsArgumentError,
    );
    expect(launched, isEmpty);
  });

  test('a missing file is reported, not revealed', () async {
    final launched = <String>[];
    await expectLater(
      reveal(launched: launched).reveal('${folder.path}/gone.txt'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          endsWith('does not exist on this computer.'),
        ),
      ),
    );
    expect(launched, isEmpty);
  });

  test('a silent bus is reported and opens no folder', () async {
    final launched = <String>[];
    await expectLater(
      reveal(answer: (_) => null, launched: launched).reveal(file),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'The file manager did not answer.',
        ),
      ),
    );
    expect(launched, ['dbus-send']);
  });

  test('every route failing is reported', () async {
    await expectLater(
      reveal(answer: (_) => (exitCode: 1, stderr: '')).reveal(file),
      throwsA(isA<StateError>()),
    );
  }, skip: Platform.isMacOS ? 'the message names Finder there' : false);
}
