// HWS/1 request encoding tests (03 §6.2, §8.8): the tick and on-demand
// lines, the argument validators, and refusal before any text.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  group('encodeTickRequest', () {
    test('lists the collectors after the sequence', () {
      expect(
        encodeTickRequest(7, [Collector.overview, Collector.core]),
        'hw_t 7 overview core\n',
      );
    });

    test('refuses an empty collector list', () {
      expect(
        () => encodeTickRequest(1, const []),
        throwsA(isA<HwsRequestError>()),
      );
    });

    test('refuses a negative sequence number', () {
      expect(
        () => encodeTickRequest(-1, [Collector.overview]),
        throwsA(isA<HwsRequestError>()),
      );
    });
  });

  group('encodeOnDemandRequest', () {
    test('produces a bare on-demand line for a zero-argument collector', () {
      expect(
        encodeOnDemandRequest(2, Collector.core, const [], quote: _quote),
        'hw_o 2 core\n',
      );
    });

    test('refuses an argument count that does not match the validators', () {
      expect(
        () => encodeOnDemandRequest(1, Collector.fs, const [
          'unexpected',
        ], quote: _quote),
        throwsA(isA<HwsRequestError>()),
      );
    });

    test('refuses a negative sequence number', () {
      expect(
        () => encodeOnDemandRequest(-1, Collector.fs, const [], quote: _quote),
        throwsA(isA<HwsRequestError>()),
      );
    });
  });

  group('ArgValidators', () {
    test('unitName accepts the systemd grammar', () {
      expect(ArgValidators.unitName('nginx.service'), isNull);
      expect(ArgValidators.unitName('foo@bar.service'), isNull);
      expect(ArgValidators.unitName('foo'), isNotNull);
      expect(ArgValidators.unitName('foo bar.service'), isNotNull);
      expect(ArgValidators.unitName(''), isNotNull);
    });

    test('userName accepts POSIX login names', () {
      expect(ArgValidators.userName('root'), isNull);
      expect(ArgValidators.userName('_apt'), isNull);
      expect(ArgValidators.userName('root\$'), isNull);
      expect(ArgValidators.userName('Root'), isNotNull);
      expect(ArgValidators.userName('1root'), isNotNull);
    });

    test('absolutePath rejects relative, unnormalized and NUL paths', () {
      expect(ArgValidators.absolutePath('/etc/hosts'), isNull);
      expect(ArgValidators.absolutePath('etc/hosts'), isNotNull);
      expect(ArgValidators.absolutePath('/etc/../hosts'), isNotNull);
      expect(ArgValidators.absolutePath('/etc/./hosts'), isNotNull);
      expect(ArgValidators.absolutePath('/etc/\u0000hosts'), isNotNull);
    });

    test('signalName accepts the enum case-insensitively', () {
      expect(ArgValidators.signalName('TERM'), isNull);
      expect(ArgValidators.signalName('term'), isNull);
      expect(ArgValidators.signalName('KILL'), isNull);
      expect(ArgValidators.signalName('NOPE'), isNotNull);
    });

    test('uint accepts non-negative decimal integers', () {
      expect(ArgValidators.uint('0'), isNull);
      expect(ArgValidators.uint('12345'), isNull);
      expect(ArgValidators.uint('-1'), isNotNull);
      expect(ArgValidators.uint('12a'), isNotNull);
      expect(ArgValidators.uint(''), isNotNull);
    });

    test(
      'journalPriority accepts severities and names, case-insensitively',
      () {
        expect(ArgValidators.journalPriority('3'), isNull);
        expect(ArgValidators.journalPriority('warning'), isNull);
        expect(ArgValidators.journalPriority('WARNING'), isNull);
        expect(ArgValidators.journalPriority('8'), isNotNull);
        expect(ArgValidators.journalPriority('nope'), isNotNull);
      },
    );

    test('journalCursor accepts only the key=hex grammar', () {
      expect(ArgValidators.journalCursor('s=abc;i=1;b=deadbeef'), isNull);
      expect(ArgValidators.journalCursor('not a cursor'), isNotNull);
      expect(ArgValidators.journalCursor('s=ZZ'), isNotNull);
      expect(ArgValidators.journalCursor(''), isNotNull);
    });

    test('calendarExpression and journalGrep reject control bytes', () {
      expect(ArgValidators.calendarExpression('daily'), isNull);
      expect(ArgValidators.calendarExpression('*-*-* 00:00:00'), isNull);
      expect(ArgValidators.calendarExpression('daily\nrm'), isNotNull);
      expect(ArgValidators.calendarExpression(''), isNotNull);
      expect(ArgValidators.journalGrep('denied'), isNull);
      expect(ArgValidators.journalGrep('\u0000'), isNotNull);
    });
  });

  test('HwsRequestError carries the collector and argument', () {
    try {
      encodeOnDemandRequest(1, Collector.fs, const ['x'], quote: _quote);
      fail('expected a refusal');
    } on HwsRequestError catch (e) {
      expect(e.collector, Collector.fs);
      expect(e.reason, contains('argument'));
    }
  });
}

String _quote(String word) => "'${word.replaceAll("'", "'\\''")}'";
