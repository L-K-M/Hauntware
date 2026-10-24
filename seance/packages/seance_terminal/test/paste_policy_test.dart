import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_terminal/seance_terminal.dart';

void main() {
  late XtermTerminalEngine engine;
  late List<String> pasted;

  setUp(() {
    engine = XtermTerminalEngine();
    pasted = [];
    // Bytes the terminal emits for a paste, decoded; bracketed paste is
    // off unless a test turns it on.
    engine.userInput.listen((bytes) => pasted.add(String.fromCharCodes(bytes)));
  });

  tearDown(() => engine.dispose());

  const finding = TerminalPasteFinding(
    severity: TerminalPasteSeverity.critical,
    line: 2,
    explanation: 'removes files recursively',
  );

  TerminalPastePolicy policy({
    List<TerminalPasteFinding> findings = const [],
    Object? inspectError,
    TerminalPasteChoice choice = TerminalPasteChoice.pasteAll,
    List<String>? inspected,
    List<TerminalPasteReview>? reviews,
  }) => TerminalPastePolicy(
    inspect: (text) async {
      inspected?.add(text);
      if (inspectError != null) throw inspectError;
      return findings;
    },
    confirm: (review) async {
      reviews?.add(review);
      return choice;
    },
  );

  Future<String> output() async {
    await pumpEventQueue();
    return pasted.join();
  }

  test('one line is cleaned and never inspected', () async {
    final inspected = <String>[];
    await policy(inspected: inspected).paste(engine, 'echo\x1b[31m hi\tthere');

    expect(await output(), 'echo[31m hi\tthere');
    expect(inspected, isEmpty);
  });

  test('empty text pastes nothing', () async {
    await policy().paste(engine, '');

    expect(await output(), isEmpty);
  });

  test('multi-line text without findings pastes without asking', () async {
    final reviews = <TerminalPasteReview>[];
    await policy(reviews: reviews).paste(engine, 'cd /srv\r\nls -l\rpwd\n');

    expect(await output(), 'cd /srv\nls -l\npwd\n');
    expect(reviews, isEmpty);
  });

  test('findings ask once, with the findings and the line count', () async {
    final reviews = <TerminalPasteReview>[];
    await policy(
      findings: [finding],
      reviews: reviews,
    ).paste(engine, 'cd /srv\nrm -rf data');

    expect(reviews, hasLength(1));
    expect(reviews.single.findings, [finding]);
    expect(reviews.single.lineCount, 2);
    expect(await output(), 'cd /srv\nrm -rf data');
  });

  test('a trailing line break is not counted as a line', () async {
    final reviews = <TerminalPasteReview>[];
    await policy(
      findings: [finding],
      reviews: reviews,
    ).paste(engine, 'cd /srv\nrm -rf data\n');

    expect(reviews.single.lineCount, 2);
  });

  test('first line only pastes the cleaned first line', () async {
    await policy(
      findings: [finding],
      choice: TerminalPasteChoice.firstLineOnly,
    ).paste(engine, 'cd /srv\x07\nrm -rf data');

    expect(await output(), 'cd /srv');
  });

  test('cancel pastes nothing', () async {
    await policy(
      findings: [finding],
      choice: TerminalPasteChoice.cancel,
    ).paste(engine, 'cd /srv\nrm -rf data');

    expect(await output(), isEmpty);
  });

  test('an inspector error asks with unknown findings', () async {
    final reviews = <TerminalPasteReview>[];
    await policy(
      inspectError: StateError('the engine is gone'),
      reviews: reviews,
      choice: TerminalPasteChoice.cancel,
    ).paste(engine, 'a\nb');

    expect(reviews.single.findings, isNull);
    expect(await output(), isEmpty);
  });

  test('bracketed paste wraps the cleaned text once, ESC removed', () async {
    // The shell turns bracketed paste on, as bash does at its prompt.
    engine.feed(Uint8List.fromList('\x1b[?2004h'.codeUnits));
    await policy().paste(engine, 'echo a\x1b[201~\necho b');

    expect(await output(), '\x1b[200~echo a[201~\necho b\x1b[201~');
  });
}
