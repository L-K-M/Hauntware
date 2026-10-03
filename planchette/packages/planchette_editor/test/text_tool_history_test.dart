import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

void main() {
  group('TextToolHistory', () {
    test('records most recent first and caps at five', () {
      final history = TextToolHistory();
      for (var i = 0; i < 7; i++) {
        history.record('numberLines', {'start': i});
      }
      expect(history.recent.length, TextToolHistory.keep);
      expect(history.last?.options['start'], 6);
      expect(history.recent.map((r) => r.options['start']), [6, 5, 4, 3, 2]);
    });

    test('an identical repeat moves to the front without duplicating', () {
      final history = TextToolHistory();
      history.record('sortLines', {'order': 'descending'});
      history.record('uppercase', {});
      history.record('sortLines', {'order': 'descending'});
      expect(history.recent.map((r) => r.toolId), ['sortLines', 'uppercase']);
    });

    test('the same tool with different options keeps both runs', () {
      final history = TextToolHistory();
      history.record('sortLines', {'order': 'descending'});
      history.record('sortLines', {'order': 'ascending'});
      expect(history.recent.length, 2);
    });

    test('notifies on each recorded run', () {
      final history = TextToolHistory();
      var notified = 0;
      history.addListener(() => notified++);
      history.record('sortLines', {});
      history.record('sortLines', {});
      expect(notified, 2);
    });

    test('lastOptionsFor returns the last-used options, then defaults', () {
      final history = TextToolHistory();
      expect(history.lastOptionsFor('numberLines')['start'], 1);
      history.record('numberLines', {'start': 10});
      expect(history.lastOptionsFor('numberLines')['start'], 10);
      // A tool that never ran still yields its declared defaults.
      expect(history.lastOptionsFor('sortLines')['order'], 'ascending');
    });

    test('restored records skip unknown tools and cap at five', () {
      final history = TextToolHistory(
        restored: [
          for (var i = 0; i < 6; i++)
            TextToolRunRecord('numberLines', {'start': i}),
          const TextToolRunRecord('notATool', {}),
        ],
      );
      expect(history.recent.length, TextToolHistory.keep);
      expect(history.recent.every((r) => r.toolId == 'numberLines'), isTrue);
    });
  });

  group('persistence', () {
    test('encode keeps a record whose text option stayed at default', () {
      final history = TextToolHistory()
        ..record('prefixSuffixLines', {
          'mode': 'insert',
          'where': 'suffix',
          'text': '',
          'skipBlankLines': true,
        });
      expect(history.encode(), hasLength(1));
    });

    test('a non-default text option keeps the record off the disk', () {
      final history = TextToolHistory()
        ..record('prefixSuffixLines', {
          'mode': 'insert',
          'where': 'prefix',
          'text': '// ',
          'skipBlankLines': true,
        });
      expect(history.encode(), isEmpty);
      // The run still counts for Repeat and Recent this session.
      expect(history.recent, hasLength(1));
    });

    test('records drop unknown keys and normalize mistyped values', () {
      final history = TextToolHistory()
        ..record('sortLines', {
          'order': 'descending',
          'ignoreCase': 'yes', // not a bool
          'madeUp': 42,
        });
      // The record holds the resolved set: the mistyped value falls back
      // to its default and the made-up key never lands.
      expect(history.last!.options['ignoreCase'], isTrue);
      expect(history.last!.options.containsKey('madeUp'), isFalse);
      expect(history.encode(), [
        {
          'id': 'sortLines',
          'options': {
            'order': 'descending',
            'numbersByValue': false,
            'byLength': false,
            'ignoreLeadingWhitespace': false,
            'keepFirstLine': false,
            'ignoreCase': true,
          },
        },
      ]);
    });

    test('a choice outside the current choices decodes to the default', () {
      final history = TextToolHistory.decode([
        {
          'id': 'sortLines',
          'options': {'order': 'spiral'},
        },
      ]);
      expect(history.last!.options['order'], 'ascending');
    });

    test('records compare and hash regardless of option order', () {
      const a = TextToolRunRecord('sortLines', {'order': 'descending'});
      const b = TextToolRunRecord('sortLines', {'order': 'descending'});
      final shuffled = TextToolRunRecord('x', {'b': 1, 'a': 2});
      final reordered = TextToolRunRecord('x', {'a': 2, 'b': 1});
      expect(a, b);
      expect(shuffled, reordered);
      expect(shuffled.hashCode, reordered.hashCode);
      // A different scope is a different run.
      expect(
        const TextToolRunRecord('sortLines', {}, wholeDocument: true),
        isNot(const TextToolRunRecord('sortLines', {})),
      );
    });

    test('wholeDocument survives the disk round-trip', () {
      final history = TextToolHistory()
        ..record('sortLines', {'order': 'descending'}, wholeDocument: true);
      expect(history.encode().first, {
        'id': 'sortLines',
        'wholeDocument': true,
        'options': isA<Map>(),
      });
      final restored = TextToolHistory.decode(history.encode());
      expect(restored.last!.wholeDocument, isTrue);
    });

    test('decode restores records and skips unreadable entries', () {
      final history = TextToolHistory.decode([
        {
          'id': 'sortLines',
          'options': {'order': 'descending', 'bogus': 'x'},
        },
        'not a map',
        {'id': 42},
        {'id': 'gone', 'options': const {}},
        {'id': 'numberLines', 'options': 'not a map'},
      ]);
      expect(history.recent.map((r) => r.toolId), ['sortLines', 'numberLines']);
      expect(history.recent.first.options['order'], 'descending');
      // Missing declared options decode to their defaults.
      expect(history.recent.first.options['ignoreCase'], isTrue);
    });

    test('a decode/encode round-trip is stable', () {
      final history = TextToolHistory()
        ..record('zapGremlins', {'action': 'entity', 'controls': false});
      final restored = TextToolHistory.decode(history.encode());
      expect(restored.encode(), history.encode());
      expect(restored.last, history.last);
    });
  });
}
