// CTX-05: a container line's level from what it says of itself, a stack
// trace's continuation taking its opener's level, and a JSON line's keys
// as fields.
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/logs/container_lines.dart';
import 'package:klabautermann_app/ui/logs/log_level.dart';
import 'package:klabautermann_app/ui/logs/log_view_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

(LogViewController, List<LogLine>) _held(List<String> texts) {
  final logs = LogViewController()
    ..addContainer([
      for (final text in texts)
        ContainerRecord(stream: ContainerLogStream.stdout, text: text),
    ]);
  return (logs, [for (var i = 0; i < logs.length; i++) logs[i] as LogLine]);
}

void main() {
  test('a level from a JSON or logfmt key, or a level word near the start', () {
    final (logs, lines) = _held([
      '{"level":"error","msg":"boom"}',
      '{"severity":"WARNING","message":"slow"}',
      '{"level":30,"msg":"pino info"}',
      '{"log":{"level":"debug"},"message":"ecs"}',
      'time=2026-10-26T12:00:00Z level=warn msg="disk"',
      '2026-10-15 14:30:01.123 UTC [1] FATAL:  password authentication failed',
      '[ERROR] could not bind',
      'WARNING:  checkpoints are occurring too frequently',
      'ValueError: bad value',
      'java.lang.IllegalStateException: closed',
      'the error count is 0',
      'GET /health 200',
    ]);
    final reader = ContainerLineReader(logs);
    expect(
      [for (final line in lines) reader.levelOf(line)],
      [
        LogLevel.error,
        LogLevel.warning,
        LogLevel.info,
        LogLevel.debug,
        LogLevel.warning,
        LogLevel.error,
        LogLevel.error,
        LogLevel.warning,
        LogLevel.error,
        LogLevel.error,
        null,
        null,
      ],
    );
  });

  test("a stack trace's continuation lines take the level of its opener", () {
    final (logs, lines) = _held([
      'ERROR request failed',
      'java.lang.NullPointerException: x',
      '    at shop.orders.Handler.run(Handler.java:42)',
      '\tat java.base/java.lang.Thread.run(Thread.java:1583)',
      'Caused by: java.io.IOException: reset',
      '    ... 3 more',
      'GET /next 200',
      '  indented after a plain line',
    ]);
    final reader = ContainerLineReader(logs);
    expect(
      [for (final line in lines) reader.levelOf(line)],
      [
        LogLevel.error,
        LogLevel.error,
        LogLevel.error,
        LogLevel.error,
        LogLevel.error,
        LogLevel.error,
        null,
        null,
      ],
    );
  });

  test("a JSON object line's keys are its fields, nested ones dotted; "
      'other lines have none', () {
    final (logs, lines) = _held([
      '{"level":"info","msg":"ok","http":{"status":200,"path":"/"},"tags":["a"]}',
      '{"broken": ',
      'plain text',
      '["not", "an", "object"]',
    ]);
    final reader = ContainerLineReader(logs);
    expect(reader.fieldsOf(lines[0]), [
      ('level', 'info'),
      ('msg', 'ok'),
      ('http.status', '200'),
      ('http.path', '/'),
      ('tags', '["a"]'),
    ]);
    expect(reader.fieldsOf(lines[1]), isNull);
    expect(reader.fieldsOf(lines[2]), isNull);
    expect(reader.fieldsOf(lines[3]), isNull);
  });

  test('skipped words and SGR escapes are not the line', () {
    final (logs, lines) = _held([
      '\x1b[38;5;33mweb-1\x1b[0m {"level":"error"}',
      '\x1b[38;5;35mdb-1\x1b[0m \x1b[33mWARNING\x1b[0m:  slow',
    ]);
    final reader = ContainerLineReader(logs, skipWords: 1);
    expect(reader.levelOf(lines[0]), LogLevel.error);
    expect(reader.fieldsOf(lines[0]), [('level', 'error')]);
    expect(reader.levelOf(lines[1]), LogLevel.warning);
  });
}
