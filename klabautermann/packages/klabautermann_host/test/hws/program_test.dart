// HWS/1 program assembly tests (03 §6.2, §6.3): the nonce line, the two
// sampler kinds, the READY marker and the no-user-text rule.
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  group('generateNonce', () {
    test('renders 128 bits as 32 hex digits', () {
      final nonce = generateNonce(Random.secure());
      expect(nonce, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('is a pure function of the supplied random source', () {
      expect(generateNonce(Random(7)), generateNonce(Random(7)));
      expect(generateNonce(Random(7)), isNot(generateNonce(Random(8))));
    });
  });

  group('collectors', () {
    test('every wire name matches the grammar', () {
      for (final c in Collector.values) {
        expect(c.wireName, matches(collectorWireNamePattern), reason: c.name);
      }
    });

    test('byName round-trips and rejects unknown names', () {
      for (final c in Collector.values) {
        expect(Collector.byName(c.wireName), c);
      }
      expect(Collector.byName('nope'), isNull);
    });

    test('the fragments cover every collector', () {
      expect(collectorFragments.keys, containsAll(Collector.values));
    });

    test('each declares the guarded calls its fragment makes (D47)', () {
      final call = RegExp(r'\bhw_q?run [a-z]');
      final loopStart = RegExp(r'(^|;)\s*do$|^\s*(for|while) .*; do$');
      for (final c in Collector.values) {
        var calls = 0;
        var depth = 0;
        for (final line in collectorFragments[c]!.split('\n')) {
          final code = line.trimLeft();
          if (code.startsWith('#')) continue;
          if (code == 'done' || code.startsWith('done ')) depth--;
          final n = call.allMatches(code).length;
          // A guarded call in a loop would run once per pass, and so
          // would one in a while or until condition on the header line.
          final inLoop =
              depth > 0 ||
              RegExp(r'\bdo\b.*\bdone\b').hasMatch(code) ||
              RegExp(r'^(while|until)\b').hasMatch(code);
          expect(inLoop && n > 0, isFalse, reason: '${c.name}: $code');
          calls += n;
          if (loopStart.hasMatch(code)) depth++;
        }
        expect(depth, 0, reason: '${c.name} loops balance');
        expect(c.guardedCommands, calls, reason: c.name);
      }
    });
  });

  group('buildSamplerProgram', () {
    const nonce = '0123456789abcdef0123456789abcdef';

    test('puts the nonce line first and nowhere else', () {
      final program = buildSamplerProgram(kind: SamplerKind.fast, nonce: nonce);
      final lines = program.split('\n');
      expect(lines.first, 'N=$nonce');
      expect(
        lines.where((l) => l.contains(nonce)),
        hasLength(1),
        reason: 'the nonce is written once',
      );
    });

    test('defines hw_t and hw_o on both samplers', () {
      for (final kind in SamplerKind.values) {
        final program = buildSamplerProgram(kind: kind, nonce: nonce);
        expect(program, contains('hw_t()'));
        expect(program, contains('hw_o()'));
        expect(program, contains('</dev/null'));
      }
    });

    test('the fast program carries only builtin collectors', () {
      final program = buildSamplerProgram(kind: SamplerKind.fast, nonce: nonce);
      expect(program, contains('c_overview()'));
      expect(program, contains('c_core()'));
      for (final c in [
        'fs',
        'identity',
        'probe',
        'procs',
        'units',
        'timers',
        'cron',
        'timer_detail',
        'ops',
      ]) {
        expect(program, isNot(contains('c_$c()')), reason: c);
      }
    });

    test('the slow program carries only forking collectors', () {
      final program = buildSamplerProgram(kind: SamplerKind.slow, nonce: nonce);
      for (final c in [
        'fs',
        'identity',
        'probe',
        'procs',
        'units',
        'timers',
        'cron',
        'timer_detail',
        'ops',
      ]) {
        expect(program, contains('c_$c()'), reason: c);
      }
      expect(program, isNot(contains('c_overview()')));
      expect(program, isNot(contains('c_core()')));
    });

    test('timer_detail shows one timer, refusing a tick without it', () {
      final fragment = collectorFragments[Collector.timerDetail]!;
      expect(fragment, contains('c_timer_detail() {'));
      expect(fragment, contains(r'if [ $# -ne 1 ]; then st=error;'));
      expect(
        fragment,
        contains(
          'hw_run systemctl show -p TimersCalendar -p TimersMonotonic '
          r'-p RandomizedDelayUSec -- "$1" </dev/null 2>&1',
        ),
      );
    });

    test('only the fast program carries the filtering readers (D48)', () {
      final fast = buildSamplerProgram(kind: SamplerKind.fast, nonce: nonce);
      final slow = buildSamplerProgram(kind: SamplerKind.slow, nonce: nonce);
      for (final helper in ['hw_meminfo', 'hw_netdev', 'hw_diskstats']) {
        expect(fast, contains('$helper() {'), reason: helper);
        expect(slow, isNot(contains(helper)), reason: helper);
      }
    });

    test('procs keeps kProcsRowCap rows, half by CPU and half by RSS', () {
      final procs = collectorFragments[Collector.procs]!;
      expect(procs, contains('if [ "\$_n" -gt $kProcsRowCap ]; then'));
      expect(procs, contains('[ "\$_i" -lt $kProcsRowCap ] || break'));
      expect(
        RegExp('head -n ${kProcsRowCap ~/ 2}(?![0-9])').allMatches(procs),
        hasLength(2),
      );
    });

    test('the READY marker is the program last line', () {
      for (final kind in SamplerKind.values) {
        final program = buildSamplerProgram(kind: kind, nonce: nonce);
        final trimmed = program.trimRight();
        expect(
          trimmed,
          endsWith(
            'printf \'\\036%s READY HWS/1 $kCollectorSetVersion\\n\' "\$N"',
          ),
        );
        expect(program, contains('READY HWS/1 $kCollectorSetVersion'));
      }
    });

    test('SELF prints the shell PID and its parent just before READY', () {
      for (final kind in SamplerKind.values) {
        final lines = buildSamplerProgram(
          kind: kind,
          nonce: nonce,
        ).trimRight().split('\n');
        expect(
          lines[lines.length - 2],
          r'''printf '\036%s SELF %s %s\n' "$N" "$$" "$PPID"''',
        );
        expect(lines.where((l) => l.contains(' SELF ')), hasLength(1));
      }
    });

    test('a bad nonce is refused before assembly', () {
      for (final bad in ['', 'xyz', '0123', 'a' * 31, 'a' * 33]) {
        expect(
          () => buildSamplerProgram(kind: SamplerKind.fast, nonce: bad),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });

  test('the probe tool list carries the documented tools', () {
    expect(
      kProbeTools,
      containsAll(<String>['journalctl', 'timeout', 'docker', 'dmesg', 'tail']),
    );
    expect(kProbeTools, hasLength(28));
  });

  test('the probe tool loop checks exactly kProbeTools, in order', () {
    // The loop is literal program text, so a tool added to only one side
    // would change the probe without a collector-set version bump.
    final program = buildSamplerProgram(
      kind: SamplerKind.slow,
      nonce: '0123456789abcdef0123456789abcdef',
    );
    final loops = RegExp(
      r'^\s*for _t in ([^;]*); do$',
      multiLine: true,
    ).allMatches(program).toList();
    expect(loops, hasLength(1), reason: 'one tool loop in _probe_tools');
    expect(loops.single.group(1)!.split(' '), kProbeTools);
  });

  group('HW_UTF8 (D49)', () {
    const nonce = '0123456789abcdef0123456789abcdef';

    test('the slow program decides it once, before any collector', () {
      final program = buildSamplerProgram(kind: SamplerKind.slow, nonce: nonce);
      expect('locale -a'.allMatches(program), hasLength(1));
      final decided = program.indexOf('HW_UTF8=1');
      expect(decided, greaterThan(program.indexOf('hw_qrun()')));
      expect(decided, lessThan(program.indexOf('c_fs()')));
      expect(decided, lessThan(program.indexOf('c_probe()')));
    });

    test('the probe reports the decision instead of checking again', () {
      final program = buildSamplerProgram(kind: SamplerKind.slow, nonce: nonce);
      final start = program.indexOf('_probe_locale() {');
      final body = program.substring(start, program.indexOf('\n}\n', start));
      expect(body, contains(r'"$HW_UTF8"'));
      expect(body, isNot(contains('locale -a')));
    });

    test('the fast program forks no locale check', () {
      final program = buildSamplerProgram(kind: SamplerKind.fast, nonce: nonce);
      expect(program, isNot(contains('HW_UTF8')));
      expect(program, isNot(contains('locale')));
    });
  });

  test('the probe asks run0 without a password (03 §8.3 rung 6)', () {
    final probe = collectorFragments[Collector.probe]!;
    expect(
      probe,
      contains('hw_qrun run0 --no-ask-password true >/dev/null 2>&1'),
    );
    expect(probe, contains(r'run0_noninteractive=$?'));
    expect(probe, contains(r'run0=absent${NL}run0_noninteractive='));
  });

  test('ops lists both directories with the documented caps', () {
    final ops = collectorFragments[Collector.ops]!;
    expect(ops, contains(r'_u=${XDG_STATE_HOME:-$HOME/.local/state}'));
    expect(ops, contains('"\$_u/$kOpsUserSubdirectory" </dev/null'));
    expect(ops, contains(' sh root $kOpsRootDirectory </dev/null'));
    expect(ops, contains('[ \$n -lt $kOpsRecordCap ] || continue'));
    expect(ops, contains('head -c ${kOpsRecordBytes + 1} "\$f"'));
    expect(ops, contains('if [ \${#c} -gt $kOpsRecordBytes ]; then'));
    // The listing script is one single-quoted word: a quote inside it
    // would end the word early.
    final start = ops.indexOf("_HW_OPS='") + "_HW_OPS='".length;
    final script = ops.substring(start, ops.indexOf("'\n", start));
    expect(script, isNot(contains("'")));
    expect(script, startsWith('exec 2>/dev/null\n'));
  });

  test('the probe reads the lxcfs mounts (D50)', () {
    final program = buildSamplerProgram(
      kind: SamplerKind.slow,
      nonce: '0123456789abcdef0123456789abcdef',
    );
    expect(program, contains('\n  _probe_lxcfs\n'));
    expect(program, contains('fuse.lxcfs:/proc/*)'));
  });

  group('kSamplerStartCommand', () {
    test('execs sh -s under the sampler environment', () {
      expect(
        kSamplerStartCommand,
        'exec env LC_ALL=C TZ=UTC SYSTEMD_PAGER= NO_COLOR=1 sh -s',
      );
    });

    test('has only words every login shell reads literally', () {
      // No quotes, globs, expansions or separators: sh, bash, zsh, fish
      // and tcsh all split it into the same words (03 §6.2).
      for (final word in kSamplerStartCommand.split(' ')) {
        expect(word, matches(RegExp(r'^[A-Za-z0-9_=-]+$')), reason: word);
      }
    });
  });
}
