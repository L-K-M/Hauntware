// HostCommands.commandLine through real login shells (03 §8.8): dash and
// bash run the line `quoteShellWord` quotes, as sshd hands an exec request
// to the account's shell, and the command must receive every hostile word
// unchanged under the exported environment. Tagged `shell`; a shell that
// is not installed gets no tests.
@Tags(['shell'])
library;

import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/local_process_link.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    if (localShell(name) case final path?) name: path,
};

/// Words a shell would act on unquoted, and the shapes 03 §6.5 names.
const _hostile = [
  '',
  ' ',
  "'",
  '"',
  r'\',
  "it's",
  r'$(touch pwned)',
  '`touch pwned`',
  ';touch pwned;#',
  '|| touch pwned &',
  r'${IFS}$((1+1))$HOME "$@" $0',
  '* ? [a] ~ !1',
  '-n',
  '--',
  'line one\nline two\n',
  '\ttab\rcr',
  'é 日本',
  '\x1e0123456789abcdef0123456789abcdef E 1',
];

Future<String> _run(LocalProcessLink link, String command) async {
  final process = await link.start(command);
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  final exit = await process.exit;
  expect(exit.exitCode, 0, reason: await err);
  return out;
}

void main() {
  for (final MapEntry(key: name, value: path) in _shells.entries) {
    group(name, () {
      late LocalProcessLink link;

      setUp(() async => link = await LocalProcessLink.create(path));
      tearDown(() => link.dispose());

      test('the command receives every word unchanged', () async {
        final out = await _run(
          link,
          HostCommands.commandLine([
            'printf',
            r'%s\000',
            ..._hostile,
          ], quote: quoteShellWord),
        );
        expect(out, _hostile.map((w) => '$w\x00').join());
        expect(
          link.workingDirectory.listSync().map((e) => e.uri.pathSegments.last),
          ['sh'],
          reason: 'a quoted word ran as a command',
        );
      });

      test('the sampler environment is exported, C.UTF-8 on request', () async {
        const probe =
            r'printf "%s|%s|%s|%s" "$LC_ALL" "$TZ" '
            r'"${SYSTEMD_PAGER-unset}" "$NO_COLOR"';
        for (final (locale, expected) in [
          (CommandLocale.c, 'C|UTC||1'),
          (CommandLocale.cUtf8, 'C.UTF-8|UTC||1'),
        ]) {
          final line = HostCommands.commandLine(
            ['sh', '-c', probe],
            quote: quoteShellWord,
            locale: locale,
          );
          expect(await _run(link, line), expected);
        }
      });

      test('the calendar read unsets TZ in its own subshell', () async {
        // onCalendar's script with printf in place of systemd-analyze.
        final argv = HostCommands.onCalendar('daily', iterations: 1);
        final script = argv[2].replaceFirst(
          'systemd-analyze calendar --iterations=1',
          r'printf "%s|%s" "${TZ-unset}"',
        );
        final line = HostCommands.commandLine([
          ...argv.take(2),
          script,
          ...argv.skip(3),
        ], quote: quoteShellWord);
        expect(await _run(link, line), 'unset|daily');
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
