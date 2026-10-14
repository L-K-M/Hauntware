// SamplerSession against real local shells (03 §6.2, D47): dash and bash
// run the start command as the login shell and as the sampler's `sh`.
// This exercises start, READY, ticks, a stalled sampler and the request
// quoting on this machine; it does not replace the SSH fixture tests.
// Tagged `shell`; a shell that is not installed gets no tests.
@Tags(['shell'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:klabautermann_core/src/sampling/sampler_session.dart';
import 'package:klabautermann_core/src/sampling/sampler_timing.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import '../support/local_process_link.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    if (localShell(name) case final path?) name: path,
};

Future<void> _ready(SamplerSession session) => session.states
    .firstWhere((s) => s is SamplerReady)
    .timeout(const Duration(seconds: 20));

SamplerSession _session(
  LocalProcessLink link,
  SamplerKind kind, {
  SamplerDeadlines deadlines = const SamplerDeadlines(),
}) => SamplerSession(
  link: link,
  kind: kind,
  quote: quoteShellWord,
  deadlines: deadlines,
  restartDelay: (_) => const Duration(milliseconds: 50),
);

/// Defines `c_echo`, which the constant program lacks: every argument
/// becomes one section, so the reply carries each word's exact bytes.
const _echoFragment =
    'c_echo() { for a in "\$@"; do hw_sec arg ok "\$a"; done; emitted=1; }\n';

/// Words a shell would act on unquoted, plus a forged end marker.
List<String> _hostileWords(String nonce) => [
  '',
  ' ',
  "'",
  '"',
  r'\',
  r"\'",
  "it's",
  r'$(touch pwned)',
  '`touch pwned`',
  ';touch pwned;#',
  '|| touch pwned &',
  r'${IFS}$((1+1))$HOME',
  '* ? [a] ~ !1',
  '-n',
  '--',
  '%s%n',
  'line one\nline two\n',
  '\ttab\rcr',
  'é 日本',
  '\x1e$nonce E 1\n\x1e$nonce B 2 1.0',
];

void main() {
  for (final MapEntry(key: name, value: path) in _shells.entries) {
    group(name, () {
      late LocalProcessLink link;

      tearDown(() => link.dispose());

      test('both samplers reach READY past a banner and tick', () async {
        link = await LocalProcessLink.create(
          path,
          startupOutput: 'Welcome\r\npartial',
        );
        final fast = _session(link, SamplerKind.fast)..start();
        await _ready(fast);
        for (final seq in [1, 2]) {
          final outcome = await fast.tick([Collector.overview, Collector.core]);
          final reply = (outcome as SamplerReplied).reply;
          expect(reply.seq, seq);
          expect(reply.uptimeSeconds, isNotNull);
          expect(reply.section('overview')!.status, SectionStatus.ok);
          expect(reply.section('core')!.status, SectionStatus.ok);
        }

        final slow = _session(link, SamplerKind.slow)..start();
        await _ready(slow);
        final tick = await slow.tick([Collector.fs, Collector.identity]);
        expect(
          (tick as SamplerReplied).reply.section('identity')!.status,
          SectionStatus.ok,
        );
        final probe = await slow.onDemand(Collector.probe, const []);
        final kernel = (probe as SamplerReplied).reply.section('probe_kernel');
        expect(kernel, isNotNull);

        await fast.close();
        await slow.close();
        expect(fast.restarts + slow.restarts, 0);
      });

      test('a SIGSTOP stall misses the deadline and restarts', () async {
        link = await LocalProcessLink.create(path);
        final session = _session(
          link,
          SamplerKind.fast,
          deadlines: const SamplerDeadlines(fastRequest: Duration(seconds: 2)),
        )..start();
        await _ready(session);
        final stalled = link.processes.single;
        expect(Process.killPid(stalled.pid, ProcessSignal.sigstop), isTrue);

        final restarted = _ready(session);
        final gap = await session.tick([Collector.overview]) as SamplerGap;
        expect(gap.reason, SamplerGapReason.deadline);
        // TERM waits while the process is stopped; the close bound ends
        // it with KILL.
        final exit = await stalled.exit.timeout(const Duration(seconds: 10));
        expect(exit.exitSignal, isNotNull);

        await restarted;
        expect(link.processes, hasLength(2));
        final outcome = await session.tick([Collector.overview]);
        expect((outcome as SamplerReplied).reply.seq, 1);
        expect(session.restarts, 1);
        await session.close();
      });

      test('hostile words round-trip through sh -s byte-exact', () async {
        link = await LocalProcessLink.create(path);
        final nonce = generateNonce(Random.secure());
        final words = _hostileWords(nonce);
        final assembler = HwsTickAssembler(nonce: nonce);
        final reply = Completer<HwsTick>();
        final process = await link.start(kSamplerStartCommand);
        final stderr = StringBuffer();
        process.stderr.transform(utf8.decoder).listen(stderr.write);
        process.stdout.listen((bytes) {
          for (final e in assembler.push(bytes)) {
            switch (e) {
              case HwsSessionReady():
                break;
              case HwsTick():
                reply.complete(e);
              case HwsTickLost() || HwsSessionFailed():
                reply.completeError(e);
            }
          }
        });

        // The line has the shape `encodeOnDemandRequest` writes; every
        // part-1 collector refuses arguments, so a test collector takes
        // them here.
        final program = buildSamplerProgram(
          kind: SamplerKind.fast,
          nonce: nonce,
        );
        final line = 'hw_o 1 echo ${words.map(quoteShellWord).join(' ')}\n';
        process.stdin.add(utf8.encode('$program$_echoFragment$line'));
        final tick = await reply.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () => fail('no reply; stderr: $stderr'),
        );
        await process.close();

        expect(tick.sections.map((s) => utf8.decode(s.payload)), words);
        expect(
          link.workingDirectory.listSync().map((e) => e.uri.pathSegments.last),
          ['sh'],
          reason: 'a quoted word ran as a command',
        );
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
