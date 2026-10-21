// `sudo -l` listing tests (03 §7.17, D66): which listed rules let root
// run a detached runner's program, from the listing spike S4 recorded
// under a rule scoped to the docker CLI and from sudoers' other forms.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// [rules] as sudo lists them for `klab`, after its defaults.
String _listing(List<String> rules) => [
  'Matching Defaults entries for klab on host:',
  '    env_reset, mail_badpass, secure_path=/usr/local/sbin\\:/usr/bin, '
      'use_pty',
  '',
  'User klab may run the following commands on host:',
  for (final rule in rules) '    $rule',
  '',
].join('\n');

void main() {
  test('a rule scoped to the docker CLI allows neither runner', () {
    // vm-sudo-docker-scoped in klabautermann/docs/evidence/s4/.
    const recorded =
        'Matching Defaults entries for klab-vm-docker on runnervmxehtw:\n'
        '    env_reset, mail_badpass, secure_path=/usr/local/sbin\\:'
        '/usr/local/bin\\:/usr/sbin\\:/usr/bin\\:/sbin\\:/bin\\:/snap/bin, '
        'use_pty\n'
        '\n'
        'User klab-vm-docker may run the following commands on '
        'runnervmxehtw:\n'
        '    (root) NOPASSWD: /usr/bin/docker\n';
    expect(sudoListAllows(recorded, 'systemd-run'), isFalse);
    expect(sudoListAllows(recorded, 'sh'), isFalse);
    expect(sudoListAllows(recorded, 'docker'), isTrue);
  });

  test('ALL as root allows every program, with or without tags', () {
    for (final rule in [
      '(ALL : ALL) ALL',
      '(ALL) NOPASSWD: ALL',
      '(root) NOPASSWD: SETENV: ALL',
    ]) {
      expect(
        sudoListAllows(_listing([rule]), 'systemd-run'),
        isTrue,
        reason: rule,
      );
    }
  });

  test('a rule naming the program allows it only without arguments', () {
    expect(
      sudoListAllows(_listing(['(root) /usr/bin/systemd-run']), 'systemd-run'),
      isTrue,
    );
    expect(
      sudoListAllows(
        _listing(['(root) /usr/bin/docker, /usr/bin/systemd-run']),
        'systemd-run',
      ),
      isTrue,
      reason: 'the second of a command list',
    );
    expect(
      sudoListAllows(
        _listing(['(root) /usr/bin/systemd-run --user']),
        'systemd-run',
      ),
      isFalse,
      reason: 'arguments restrict the command to exactly those',
    );
    expect(
      sudoListAllows(
        _listing(['(root) /usr/bin/systemd-run *']),
        'systemd-run',
      ),
      isTrue,
      reason: 'a lone * matches any arguments',
    );
  });

  test('another run-as user does not count', () {
    expect(
      sudoListAllows(_listing(['(www-data) NOPASSWD: ALL']), 'systemd-run'),
      isFalse,
    );
    expect(
      sudoListAllows(_listing(['(www-data, root) ALL']), 'systemd-run'),
      isTrue,
    );
  });

  test('a negated entry naming the program denies it', () {
    expect(
      sudoListAllows(
        _listing(['(ALL) ALL, !/usr/bin/systemd-run']),
        'systemd-run',
      ),
      isFalse,
    );
    expect(
      sudoListAllows(_listing(['(ALL) ALL, !/usr/bin/su']), 'systemd-run'),
      isTrue,
    );
    expect(
      sudoListAllows(
        _listing(['(ALL) !/usr/bin/systemd-run', '(root) ALL']),
        'systemd-run',
      ),
      isTrue,
      reason: 'the last match wins',
    );
  });

  test('a negated glob that matches the program denies it', () {
    for (final negated in [
      '!/usr/bin/systemd-run*',
      '!/usr/bin/systemd-?un',
      '!/usr/bin/systemd-[rx]un',
      '!/usr/bin/*',
      '!/usr/*/systemd-run',
    ]) {
      expect(
        sudoListAllows(_listing(['(ALL) ALL, $negated']), 'systemd-run'),
        isFalse,
        reason: negated,
      );
    }
    expect(
      sudoListAllows(_listing(['(ALL) ALL, !/usr/bin/su*']), 'systemd-run'),
      isTrue,
    );
    expect(
      sudoListAllows(_listing(['(ALL) ALL, !/usr/bin/[!s]*']), 'systemd-run'),
      isTrue,
    );
  });

  test("a bracket's leading ], ^ negation and escapes read as fnmatch "
      'reads them', () {
    bool allows(String negated) =>
        sudoListAllows(_listing(['(ALL) ALL, $negated']), 'systemd-run')!;

    // `[!]]` is "anything but ]", which `s` is.
    expect(allows('!/usr/bin/[!]]ystemd-run'), isFalse);
    expect(allows('!/usr/bin/[^x]ystemd-run'), isFalse);
    // `[]s]` holds `]` and `s`.
    expect(allows('!/usr/bin/[]s]ystemd-run'), isFalse);
    // `[\d]` is the letter d, not a digit class.
    expect(allows(r'!/usr/bin/systemd-run[\d]'), isTrue);
    // An escaped `*` is a literal star, which the name lacks.
    expect(allows(r'!/usr/bin/systemd-run\*'), isTrue);
    // A bracket that never closes is a literal `[`.
    expect(allows('!/usr/bin/systemd-run[*'), isTrue);
    // A reversed range is empty, as fnmatch(3) reads it, not an error;
    // the set's other members still match.
    expect(allows('!/usr/bin/[z-a]*'), isTrue);
    expect(allows('!/usr/bin/[z-as]ystemd-run'), isFalse);
    // A `-` first or last in a set is a member.
    expect(allows('!/usr/bin/systemd[-x]run'), isFalse);
    expect(allows('!/usr/bin/systemd[x-]run'), isFalse);
    expect(allows('!/usr/bin/[r-t]ystemd-run'), isFalse);
  });

  test('a negated directory denies every program in it', () {
    expect(
      sudoListAllows(_listing(['(ALL) ALL, !/usr/bin/']), 'systemd-run'),
      isFalse,
    );
    expect(
      sudoListAllows(_listing(['(root) /usr/bin/']), 'systemd-run'),
      isFalse,
      reason:
          'a directory never allows, since the program may live '
          'elsewhere',
    );
  });

  test('a later allow wins over an earlier negated glob', () {
    expect(
      sudoListAllows(
        _listing([
          '(ALL) ALL, !/usr/bin/systemd-*',
          '(root) /usr/bin/systemd-run',
        ]),
        'systemd-run',
      ),
      isTrue,
    );
  });

  test('a glob that would allow the program does not count', () {
    // Only the base name is known, not where the program lives, so a
    // glob allows nothing; sudo would refuse a runner it does not cover.
    expect(
      sudoListAllows(_listing(['(root) /usr/bin/systemd-*']), 'systemd-run'),
      isFalse,
    );
  });

  test("each command's own tags are read past", () {
    expect(
      sudoListAllows(
        _listing([
          '(root) NOPASSWD: /usr/bin/ls, NOEXEC: /usr/bin/systemd-run',
        ]),
        'systemd-run',
      ),
      isTrue,
    );
    expect(
      sudoListAllows(
        _listing(['(ALL) ALL, NOPASSWD: !/usr/bin/systemd-run']),
        'systemd-run',
      ),
      isFalse,
    );
  });

  test("a command's options such as CWD= read like its tags", () {
    expect(
      sudoListAllows(
        _listing(['(root) CWD=/srv NOPASSWD: /usr/bin/systemd-run']),
        'systemd-run',
      ),
      isTrue,
    );
    expect(
      sudoListAllows(
        _listing(['(ALL) ALL, CHROOT=/jail TIMEOUT=5m !/usr/bin/systemd-run']),
        'systemd-run',
      ),
      isFalse,
    );
  });

  test('a user with no rule may run nothing', () {
    expect(
      sudoListAllows(
        'User klab is not allowed to run sudo on host.\n',
        'systemd-run',
      ),
      isFalse,
    );
  });

  test('output without a listing tells nothing', () {
    expect(
      sudoListAllows('sudo: a password is required\n', 'systemd-run'),
      isNull,
    );
    expect(
      sudoListAllows('sudo: interactive authentication is required\n', 'sh'),
      isNull,
      reason: "sudo-rs's refusal",
    );
    expect(sudoListAllows('', 'sh'), isNull);
  });

  test('the listing ends at the next unindented line', () {
    final output =
        '${_listing(['(root) /usr/bin/docker'])}'
        'Runas and Command-specific defaults for klab:\n'
        '    (root) ALL\n';
    expect(sudoListAllows(output, 'systemd-run'), isFalse);
  });
}
