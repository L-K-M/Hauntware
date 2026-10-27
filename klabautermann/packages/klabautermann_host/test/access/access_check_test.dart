// Access-check rule tests (CN-24, CN-09, LOG-04, SAF-08; 03 §6.1, §8.1,
// §8.3, §8.4, §10.4): one table per fixture platform, then the cases the
// fixtures do not cover. Unknown is never shown as missing or zero.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

import 'support.dart';

typedef R = AccessReason;
typedef I = AccessItem;

const _ok = AccessStatus.ok;
const _missing = AccessStatus.missing;
const _unknown = AccessStatus.unknown;

/// A row as (status, reason, copyable fix joined by spaces, SAF-08 flag).
typedef _Row = (AccessStatus, AccessReason, String?, bool);

_Row _row(AccessRow r) =>
    (r.status, r.reason, r.fix?.commandLine.join(' '), r.rootEquivalent);

_Row _of(HostProfile p, AccessItem item) => _row(evaluateAccess(p).row(item));

/// Password sudo: no fix until SAF-17's narrow rules (03 §8.1).
const _passwordSudo = (_missing, R.sudoNotPasswordless, null, true);
const _pending = (_unknown, R.dockerEndpointPending, null, false);
const _composePending = (_unknown, R.composeNotChecked, null, false);
const _noSocket = (_missing, R.noEngineSocket, null, false);
const _noEngine = (_missing, R.noEngine, null, false);
const _json = (_ok, R.systemdJson, null, false);

final _tables = <String, Map<AccessItem, _Row>>{
  // Password sudo, no journal group, no engine, systemd 252.
  'debian-12': {
    I.sudoNoPassword: _passwordSudo,
    I.journal: (
      _missing,
      R.notInJournalGroup,
      'sudo usermod -aG systemd-journal anke',
      false,
    ),
    I.dockerSocket: _noSocket,
    I.streamlocal: _pending,
    I.composePlugin: _composePending,
    I.systemd: _json,
    I.runtime: _noEngine,
  },
  // NOPASSWD sudo, adm, a writable rootful Docker socket, systemd 255.
  'ubuntu-2404': {
    I.sudoNoPassword: (_ok, R.sudoNoPassword, null, true),
    I.journal: (_ok, R.journalGroup, null, false),
    I.dockerSocket: (_ok, R.rootfulSocket, null, true),
    I.streamlocal: _pending,
    I.composePlugin: _composePending,
    I.systemd: _json,
    I.runtime: (_ok, R.enginesDetected, null, false),
  },
  // Password sudo, wheel, no engine, systemd 239 (text fallback, CN-10).
  'rhel-8': {
    I.sudoNoPassword: _passwordSudo,
    I.journal: (_ok, R.journalGroup, null, false),
    I.dockerSocket: _noSocket,
    I.streamlocal: _pending,
    I.composePlugin: _composePending,
    I.systemd: (_ok, R.systemdTextFallback, null, false),
    I.runtime: _noEngine,
  },
  // doas with a password, no journal, OpenRC, no engine.
  'alpine-322': {
    I.sudoNoPassword: (_missing, R.doasNotPasswordless, null, true),
    I.journal: (_missing, R.noJournal, null, false),
    I.dockerSocket: _noSocket,
    I.streamlocal: _pending,
    I.composePlugin: _composePending,
    I.systemd: (_missing, R.notSystemd, null, false),
    I.runtime: _noEngine,
  },
};

void main() {
  group('platform tables', () {
    for (final platform in fixturePlatforms) {
      test(platform, () {
        final report = evaluateAccess(fixtureProfile(platform));
        expect(report.rows.map((r) => r.item), AccessItem.values);
        expect({
          for (final r in report.rows) r.item: _row(r),
        }, _tables[platform]);
      });
    }

    test('the LOG-04 notice follows the journal row', () {
      bool? limited(String p) =>
          evaluateAccess(fixtureProfile(p)).journalLimited;
      expect(limited('debian-12'), true);
      expect(limited('ubuntu-2404'), false);
      expect(limited('rhel-8'), false);
      // No journal at all: nothing is silently truncated.
      expect(limited('alpine-322'), null);
    });

    test('runtimes per host come from the existing sockets (CN-09)', () {
      final ubuntu = evaluateAccess(fixtureProfile('ubuntu-2404')).engines;
      expect(ubuntu.map((e) => (e.runtime, e.mode, e.socket.path)), [
        (EngineRuntime.docker, EngineMode.rootful, '/var/run/docker.sock'),
      ]);
      expect(evaluateAccess(fixtureProfile('debian-12')).engines, isEmpty);
    });
  });

  group('unknown is never shown as missing', () {
    test('a profile without probe answers is unknown on every row', () {
      final report = evaluateAccess(HostProfile());
      for (final r in report.rows) {
        expect((r.status, r.fix), (_unknown, null), reason: r.item.name);
      }
      expect(report.journalLimited, isNull);
      expect(report.engines, isEmpty);
    });

    test('denied probe areas leave every row unknown', () {
      final sections = [
        for (final area in 'distro init identity elev tools sockets'.split(' '))
          ProbeSection(area, SectionStatus.denied, ''),
      ];
      final profile = parseProbe(sections, ParseContext.standard).value;
      for (final r in evaluateAccess(profile).rows) {
        expect(r.status, _unknown, reason: r.item.name);
      }
    });

    test('a denied identity area leaves the journal row unknown', () {
      final p = host(
        uid: null,
        user: null,
        groups: const [],
        denied: {'identity'},
      );
      expect(_of(p, I.journal), (
        _unknown,
        R.probeAreaUnavailable,
        null,
        false,
      ));
    });

    test('a denied sockets area leaves the engine rows unknown', () {
      final p = host(denied: {'sockets'});
      for (final item in [I.dockerSocket, I.runtime]) {
        expect(_of(p, item), (
          _unknown,
          R.probeAreaUnavailable,
          null,
          false,
        ), reason: item.name);
      }
    });

    test('an unanswered sudo -n stays unknown', () {
      expect(_of(host(sudoNonInteractive: null), I.sudoNoPassword), (
        _unknown,
        R.probeAreaUnavailable,
        null,
        false,
      ));
    });

    test('a journal group check without a tools answer stays unknown', () {
      expect(_of(host(tools: const {}), I.journal).$1, _unknown);
    });

    test('an unparsed or untested systemd version is unknown', () {
      expect(_of(host(systemdVersion: null), I.systemd), (
        _unknown,
        R.systemdVersionUnparsed,
        null,
        false,
      ));
      expect(_of(host(systemdVersion: 219), I.systemd), (
        _unknown,
        R.systemdOlderThanTested,
        null,
        false,
      ));
    });
  });

  group('elevation', () {
    test('a root login needs neither sudo nor a journal group', () {
      final root = host(uid: 0, user: 'root', groups: const ['root']);
      expect(_of(root, I.sudoNoPassword), (_ok, R.rootLogin, null, false));
      expect(_of(root, I.journal), (_ok, R.rootLogin, null, false));
    });

    test('blanket doas permit nopass counts where sudo is absent', () {
      final doas = host(
        sudoKind: SudoKind.none,
        sudoNonInteractive: null,
        doasPresent: true,
        doasNonInteractive: true,
      );
      expect(_of(doas, I.sudoNoPassword), (_ok, R.doasNoPassword, null, true));
    });

    test('no sudo and no doas is missing without a fix', () {
      expect(_of(host(sudoKind: SudoKind.none), I.sudoNoPassword), (
        _missing,
        R.noElevationTool,
        null,
        false,
      ));
    });

    test('password sudo offers no blanket NOPASSWD rule', () {
      // A broad rule equals root (SAF-08) and password sudo already
      // reaches admin mode (03 §8.3 rung 3); narrow rules are SAF-17.
      final row = evaluateAccess(host(user: 'anke')).row(I.sudoNoPassword);
      expect(_row(row), _passwordSudo);
    });

    test('a user name outside the grammar gets no fix', () {
      final report = evaluateAccess(
        host(user: 'Bad User;rm', sockets: [socket('/var/run/docker.sock')]),
      );
      expect(report.row(I.journal).status, _missing);
      expect(report.row(I.journal).fix, isNull);
      expect(report.row(I.dockerSocket).status, _missing);
      expect(report.row(I.dockerSocket).fix, isNull);
    });

    test('the fix prefix follows the elevation', () {
      final argv = ['usermod', '-aG', 'docker', 'ops'];
      expect(AccessFix(argv, FixElevation.sudo).commandLine.first, 'sudo');
      expect(AccessFix(argv, FixElevation.doas).commandLine.first, 'doas');
      expect(AccessFix(argv, FixElevation.none).commandLine, argv);
      expect(AccessFix(argv, FixElevation.rootShell).commandLine, argv);
      final noTool = host(sudoKind: SudoKind.none);
      expect(
        evaluateAccess(noTool).row(I.journal).fix!.elevation,
        FixElevation.rootShell,
      );
    });
  });

  group('Docker socket rights (SAF-08)', () {
    const rootfulDocker = '/var/run/docker.sock';

    test('a writable rootless socket is user-equivalent', () {
      final p = host(
        sockets: [socket('/run/user/1000/podman/podman.sock', writable: true)],
      );
      expect(_of(p, I.dockerSocket), (_ok, R.rootlessSocket, null, false));
      final engine = evaluateAccess(p).engines.single;
      expect(
        (engine.runtime, engine.mode),
        (EngineRuntime.podman, EngineMode.rootless),
      );
    });

    test('an unreachable rootful Docker socket offers the docker group', () {
      expect(_of(host(sockets: [socket(rootfulDocker)]), I.dockerSocket), (
        _missing,
        R.socketNotWritable,
        'sudo usermod -aG docker ops',
        true,
      ));
    });

    test('BusyBox userlands get addgroup, elevated through doas', () {
      final alpine = host(
        distroId: 'alpine',
        sudoKind: SudoKind.none,
        doasPresent: true,
        doasNonInteractive: false,
        sockets: [socket(rootfulDocker)],
      );
      expect(_of(alpine, I.dockerSocket).$3, 'doas addgroup ops docker');
    });

    test('no group advice when the user is already in docker', () {
      final member = host(
        groups: const ['ops', 'docker'],
        sockets: [socket(rootfulDocker)],
      );
      expect(_of(member, I.dockerSocket).$1, _missing);
      expect(_of(member, I.dockerSocket).$3, isNull);
    });

    test('a rootful Podman socket has no group to suggest', () {
      expect(
        _of(host(sockets: [socket('/run/podman/podman.sock')]), I.dockerSocket),
        (_missing, R.socketNotWritable, null, true),
      );
    });

    test('any writable rootful socket makes the row root-equivalent', () {
      final both = host(
        sockets: [
          socket(rootfulDocker, writable: true),
          socket('/run/user/1000/docker.sock', writable: true),
        ],
      );
      expect(_of(both, I.dockerSocket), (_ok, R.rootfulSocket, null, true));
    });
  });

  group('runtime per host (CN-09)', () {
    test('a CLI without any socket is reported as such', () {
      final cli = host(tools: const {'docker': '/usr/bin/docker'});
      expect(_of(cli, I.runtime), (
        _missing,
        R.engineCliWithoutSocket,
        null,
        false,
      ));
    });

    test('Podman without a socket offers to enable it (CN-25): the '
        "login's own, or root's system socket", () {
      const podman = {'podman': '/usr/bin/podman', 'docker': '/usr/bin/docker'};
      expect(_of(host(tools: podman), I.runtime), (
        _missing,
        R.engineCliWithoutSocket,
        'systemctl --user enable --now podman.socket',
        false,
      ));
      expect(
        _of(host(tools: podman, uid: 0, user: 'root'), I.runtime).$3,
        'systemctl enable --now podman.socket',
      );
      expect(
        _of(host(tools: podman, systemdDir: false), I.runtime).$3,
        isNull,
        reason: 'no unit to enable',
      );
      expect(_of(host(tools: podman, uid: null), I.runtime).$3, isNull);
    });

    test('socket paths classify into runtime and mode', () {
      const docker = EngineRuntime.docker, podman = EngineRuntime.podman;
      const rootful = EngineMode.rootful, rootless = EngineMode.rootless;
      final cases = {
        '/var/run/docker.sock': (docker, rootful),
        '/run/docker.sock': (docker, rootful),
        '/run/podman/podman.sock': (podman, rootful),
        '/run/user/1001/docker.sock': (docker, rootless),
        '/run/user/0/podman/podman.sock': (podman, rootless),
        '/tmp/docker.sock': null,
        '/run/user/x/docker.sock': null,
        '/run/user/1000/podman.sock': null,
      };
      for (final MapEntry(key: path, value: want) in cases.entries) {
        final e = classifyEngineSocket(socket(path));
        expect(e == null ? null : (e.runtime, e.mode), want, reason: path);
      }
    });

    test('absent sockets are not engines', () {
      final p = host(sockets: [socket('/var/run/docker.sock', exists: false)]);
      expect(evaluateAccess(p).engines, isEmpty);
      expect(_of(p, I.runtime), _noEngine);
    });
  });

  group('the Docker endpoint\'s facts (CN-24, CN-09)', () {
    _Row docker(AccessItem item, DockerAccessFacts facts, [HostProfile? p]) =>
        _row(evaluateAccess(p ?? host(), docker: facts).row(item));

    test('streamlocal follows the ladder, unknown until it ran', () {
      final cases = <StreamlocalAccess?, _Row>{
        null: _pending,
        StreamlocalAccess.allowed: (_ok, R.streamlocalAllowed, null, false),
        StreamlocalAccess.disabled: (
          _missing,
          R.streamlocalDisabled,
          null,
          false,
        ),
        StreamlocalAccess.socketDenied: (
          _missing,
          R.streamlocalSocketDenied,
          null,
          false,
        ),
        StreamlocalAccess.untested: (
          _unknown,
          R.streamlocalUntested,
          null,
          false,
        ),
      };
      for (final MapEntry(key: access, value: want) in cases.entries) {
        expect(
          docker(I.streamlocal, DockerAccessFacts(streamlocal: access)),
          want,
          reason: '$access',
        );
      }
    });

    test('the compose plugin, a standalone binary, v1, or none', () {
      final cases = <ComposeFacts, _Row>{
        const ComposeFacts(
          pluginVersion: '2.29.7',
          standaloneVersion: '1.29.2',
        ): (
          _ok,
          R.composePlugin,
          null,
          false,
        ),
        const ComposeFacts(standaloneVersion: '2.29.7'): (
          _missing,
          R.composeStandaloneOnly,
          null,
          false,
        ),
        const ComposeFacts(standaloneVersion: '1.29.2', standaloneLegacy: true):
            (_missing, R.composeLegacyOnly, null, false),
        const ComposeFacts(): (_missing, R.noCompose, null, false),
      };
      for (final MapEntry(key: compose, value: want) in cases.entries) {
        expect(
          docker(I.composePlugin, DockerAccessFacts(compose: compose)),
          want,
          reason: '$want',
        );
      }
    });

    test('compose stays unknown until checked, and says a failed check', () {
      expect(
        docker(I.composePlugin, const DockerAccessFacts()),
        _composePending,
      );
      expect(
        docker(
          I.composePlugin,
          const DockerAccessFacts(composeCheckFailed: true),
        ),
        (_unknown, R.composeCheckFailed, null, false),
      );
    });

    test('a socket chosen on the device reads as chosen manually while '
        'in use or unsettled, and unavailable otherwise', () {
      const chosen = '/srv/engine.sock';
      // Even before the probe answered its sockets.
      final unanswered = host(denied: {'sockets'});
      for (final inUse in [true, null]) {
        expect(
          docker(
            I.runtime,
            DockerAccessFacts(chosenSocket: chosen, chosenSocketInUse: inUse),
            unanswered,
          ),
          (_ok, R.runtimeChosenManually, null, false),
          reason: '$inUse',
        );
      }
      expect(
        docker(
          I.runtime,
          const DockerAccessFacts(
            chosenSocket: chosen,
            chosenSocketInUse: false,
          ),
        ),
        (_missing, R.runtimeChosenUnavailable, null, false),
      );
      // Without a choice the probe's runtimes decide, as before.
      expect(docker(I.runtime, const DockerAccessFacts()), _noEngine);
    });

    test('the facts change no host row', () {
      final p = fixtureProfile('ubuntu-2404');
      const facts = DockerAccessFacts(
        streamlocal: StreamlocalAccess.allowed,
        compose: ComposeFacts(pluginVersion: '2.29.7'),
      );
      final plain = evaluateAccess(p).rows;
      final withFacts = evaluateAccess(p, docker: facts).rows;
      for (final item in [
        I.sudoNoPassword,
        I.journal,
        I.dockerSocket,
        I.systemd,
        I.runtime,
      ]) {
        expect(
          _row(withFacts[item.index]),
          _row(plain[item.index]),
          reason: item.name,
        );
      }
    });
  });
}
