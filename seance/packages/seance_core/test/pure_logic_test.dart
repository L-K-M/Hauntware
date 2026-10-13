import 'package:seance_core/src/hostkey/tofu.dart';
import 'package:seance_core/src/llm/danger_linter.dart';
import 'package:seance_core/src/llm/redaction.dart';
import 'package:seance_core/src/ssh_config/ssh_config_import.dart';
import 'package:seance_core/src/terminal/paste_sanitizer.dart';
import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

class _MemHostKeyStore implements HostKeyStore {
  final _map = <String, HostKey>{};
  @override
  Future<List<HostKey>> all() async => _map.values.toList();
  @override
  Future<HostKey?> get(String host, int port) async => _map['$host:$port'];
  @override
  Future<void> put(HostKey key) async => _map[key.locator] = key;
}

/// One F2d danger rule: its explanation and severity, commands that must
/// raise exactly its finding, and near misses that must not raise it.
typedef _DangerRuleCase = ({
  String explanation,
  DangerSeverity severity,
  List<String> fires,
  List<String> misses,
});

void main() {
  group('SshConfigImporter', () {
    test('parses hosts, ignores wildcard-only defaults and comments', () {
      const text = '''
# global defaults
Host *
  ServerAliveInterval 60

Host prod
  HostName prod.example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/prod_ed25519

Host bastion db
  HostName 10.0.0.5
  ProxyJump prod
''';
      final hosts = SshConfigImporter.parse(text);
      expect(hosts.map((h) => h.alias), ['prod', 'bastion']);

      final prod = hosts.first;
      expect(prod.hostName, 'prod.example.com');
      expect(prod.port, 2222);
      expect(prod.user, 'deploy');
      expect(prod.identityFile, '~/.ssh/prod_ed25519');

      final bastion = hosts[1];
      expect(bastion.effectiveHost, '10.0.0.5');
      expect(bastion.proxyJump, 'prod');
    });

    test('supports Key=value form and quoted values', () {
      const text = 'Host x\n  HostName=x.example.com\n  User="root"\n';
      final h = SshConfigImporter.parse(text).single;
      expect(h.hostName, 'x.example.com');
      expect(h.user, 'root');
    });

    test('accepts one = with whitespace around it, as ssh does', () {
      const text =
          'Host = x\n'
          '  HostName = "x.example.com"\n'
          '  User =deploy\n'
          '  Port= 2222\n'
          '  IdentityFile  =  ~/.ssh/id\n';
      final h = SshConfigImporter.parse(text).single;
      expect(h.alias, 'x');
      expect(h.hostName, 'x.example.com');
      expect(h.user, 'deploy');
      expect(h.port, 2222);
      expect(h.identityFile, '~/.ssh/id');
    });

    test('splits and unquotes arguments as ssh does', () {
      const text =
          'Host x\n'
          // Quotes keep spaces and `#` in one argument.
          '  IdentityFile "~/My Keys/#1"\n'
          // Single quotes count too, as in ssh's argv_split().
          "  User 'ops'\n"
          // A `#` starts a comment only where an argument would start.
          '  HostName x.example.com # comment\n'
          '  ProxyJump jump#2\n';
      final h = SshConfigImporter.parse(text).single;
      expect(h.identityFile, '~/My Keys/#1');
      expect(h.user, 'ops');
      expect(h.hostName, 'x.example.com');
      expect(h.proxyJump, 'jump#2');

      // A backslash escapes a space or a quote; any other one is kept.
      final escaped = SshConfigImporter.parse(r'''
Host y
  IdentityFile ~/My\ Keys/\"id\"\x
''').single;
      expect(escaped.identityFile, r'~/My Keys/"id"\x');

      // ssh rejects an unterminated quote; the importer reads it to the end
      // of the line rather than dropping the value.
      final open = SshConfigImporter.parse('Host z\n  User "ops\n').single;
      expect(open.user, 'ops');

      // A directive with no value is absent, so the alias is the address.
      final blank = SshConfigImporter.parse('Host b\n  HostName=\n').single;
      expect(blank.hostName, isNull);
      expect(blank.effectiveHost, 'b');
    });

    test('converts to a ServerConfig with reference-not-store key auth', () {
      final h = SshConfigImporter.parse(
        'Host x\n HostName h\n IdentityFile ~/.ssh/id\n',
      ).single;
      final cfg = h.toServerConfig(id: 'id1', now: 5);
      expect(cfg.authMethod, AuthMethod.privateKey);
      expect(cfg.identityFilePath, '~/.ssh/id');
      // OpenSSH tries the agent for a keyless host, so imports do the same.
      final keylessCfg = SshConfigImporter.parse(
        'Host y\n HostName h\n',
      ).single.toServerConfig(id: 'id2', now: 5);
      expect(keylessCfg.authMethod, AuthMethod.agent);
    });
  });

  group('TofuVerifier', () {
    // The SSH library hands us a SHA-256 fingerprint at connect time, so keys
    // are identified by fingerprint here.
    HostKey key(String fp) => HostKey(
      host: 'h',
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:$fp',
      pinnedAt: 0,
    );

    test('first use, then trusted, then changed', () async {
      final v = TofuVerifier(_MemHostKeyStore());
      final first = await v.check(key('AAAA'));
      expect(first.verdict, HostKeyVerdict.firstUse);

      await v.pin(key('AAAA'));
      final second = await v.check(key('AAAA'));
      expect(second.verdict, HostKeyVerdict.trusted);

      final changed = await v.check(key('BBBB'));
      expect(changed.verdict, HostKeyVerdict.changed);
      expect(changed.pinned!.fingerprintSha256, 'SHA256:AAAA');
      expect(changed.presented.fingerprintSha256, 'SHA256:BBBB');
    });

    test('never auto-updates a changed key', () async {
      final store = _MemHostKeyStore();
      final v = TofuVerifier(store);
      await v.pin(key('AAAA'));
      await v.check(key('EVIL'));
      expect((await store.get('h', 22))!.fingerprintSha256, 'SHA256:AAAA');
    });
  });

  group('DangerLinter', () {
    test('flags critical destructive commands', () {
      expect(DangerLinter.worst('rm -rf /'), DangerSeverity.critical);
      expect(DangerLinter.worst('sudo rm -rf ~/'), DangerSeverity.critical);
      expect(
        DangerLinter.worst('dd if=/dev/zero of=/dev/sda'),
        DangerSeverity.critical,
      );
      expect(
        DangerLinter.worst('mkfs.ext4 /dev/sdb1'),
        DangerSeverity.critical,
      );
      expect(DangerLinter.worst(':(){ :|:& };:'), DangerSeverity.critical);
    });

    test('flags recursive delete of a specific system directory', () {
      // These slipped through the old rule (which only matched a bare /, ~, *).
      expect(DangerLinter.worst('rm -rf /etc'), DangerSeverity.critical);
      expect(DangerLinter.worst('sudo rm -rf /var/lib'), DangerSeverity.critical);
      expect(DangerLinter.worst('rm -fr /usr/local'), DangerSeverity.critical);
      expect(DangerLinter.worst('rm -rf *'), DangerSeverity.critical);
      expect(DangerLinter.worst('wipefs -a /dev/sdb'), DangerSeverity.critical);
    });

    test('warns on risky-but-common patterns', () {
      expect(
        DangerLinter.worst('curl https://x.sh | sudo bash'),
        DangerSeverity.warning,
      );
      expect(
        DangerLinter.worst('chmod -R 777 /var/www'),
        DangerSeverity.warning,
      );
      expect(DangerLinter.worst('sudo reboot'), DangerSeverity.warning);
      expect(DangerLinter.worst('shred -u secret.key'), DangerSeverity.warning);
      expect(
        DangerLinter.worst('find . -name "*.log" -delete'),
        DangerSeverity.warning,
      );
      expect(DangerLinter.worst('truncate -s 0 app.log'), DangerSeverity.warning);
      expect(DangerLinter.worst('git clean -fdx'), DangerSeverity.warning);
    });

    test('leaves benign commands alone', () {
      expect(DangerLinter.worst('ls -la'), isNull);
      expect(DangerLinter.worst('git status'), isNull);
      expect(DangerLinter.worst('rm build/output.o'), isNull);
      // A recursive delete of a RELATIVE path is not flagged (no leading /,~,*).
      expect(DangerLinter.worst('rm -rf ./build'), isNull);
      expect(DangerLinter.worst('rm -rf node_modules'), isNull);
      // git clean dry-run and non-forced finds are fine.
      expect(DangerLinter.worst('git clean -n'), isNull);
      expect(DangerLinter.worst('find . -name "*.log"'), isNull);
    });

    // Docker, systemd, cron, firewall and account rules from
    // docs/design/seance-core-transport.md §3.6, one table per rule: every
    // firing command raises exactly that rule's finding, and no near miss
    // raises it.
    group('F2d rules', () {
      const critical = DangerSeverity.critical;
      const warning = DangerSeverity.warning;
      final rules = <_DangerRuleCase>[
        (
          explanation:
              'docker system prune --all deletes every unused image; '
              '--volumes also deletes unused volumes and their data.',
          severity: critical,
          fires: [
            'docker system prune -a --volumes',
            'docker system prune --all',
            'docker system prune --volumes',
            'docker system prune -a',
            'docker system prune -af',
            'docker system prune -fa',
            'sudo docker system prune --all --force',
          ],
          misses: [
            'docker system prune',
            'docker system prune -f',
            'docker system prune --filter until=24h',
            'docker system df',
          ],
        ),
        (
          explanation:
              'Removes unused volumes and their data (named ones too with '
              '--all or before Docker 23).',
          severity: critical,
          fires: [
            'docker volume prune',
            'docker volume prune -f',
            'sudo docker volume prune --all',
          ],
          misses: ['docker volume ls', 'docker volume inspect pgdata'],
        ),
        (
          explanation: 'Deletes a named volume and its data.',
          severity: warning,
          fires: [
            'docker volume rm pgdata',
            'docker volume rm -f pgdata cache',
          ],
          misses: [
            'docker volume ls',
            'docker volume create pgdata',
            'docker rm -f web',
          ],
        ),
        (
          explanation: 'compose down -v drops the stack\'s volumes.',
          severity: critical,
          fires: [
            'docker compose down -v',
            'docker compose down --volumes',
            'docker compose -f f.yaml down -v',
            'docker-compose down -v',
            'docker compose -p web down --rmi all -v',
          ],
          misses: [
            'docker compose down',
            'docker compose down --remove-orphans',
            'docker compose up -d',
            'docker run -v /a:/b nginx',
          ],
        ),
        (
          explanation:
              'Stopping or masking sshd cuts future SSH access to the host.',
          severity: warning,
          fires: [
            'systemctl stop sshd',
            'sudo systemctl disable ssh',
            'systemctl mask ssh.service',
            'systemctl disable --now ssh.socket',
          ],
          misses: [
            'systemctl status sshd',
            'systemctl restart sshd',
            'systemctl stop nginx',
          ],
        ),
        (
          explanation: 'crontab -r deletes the user\'s whole cron table.',
          severity: warning,
          fires: ['crontab -r', 'crontab -u deploy -r', 'crontab -ir'],
          // The r in a user name is not the -r flag.
          misses: ['crontab -l', 'crontab -e', 'crontab -u rob -l'],
        ),
        (
          explanation: 'Removes or switches off the firewall.',
          severity: warning,
          fires: [
            'ufw reset',
            'ufw --force reset',
            'ufw disable',
            'sudo ufw --force disable',
          ],
          misses: [
            'ufw status',
            'ufw status verbose',
            'ufw allow 22/tcp',
            'ufw enable',
          ],
        ),
        (
          explanation: 'Drops the entire nftables ruleset.',
          severity: warning,
          fires: ['nft flush ruleset', 'sudo nft flush ruleset'],
          misses: ['nft list ruleset'],
        ),
        (
          explanation: 'Removes a user account.',
          severity: warning,
          // -R names a chroot directory, not a removal.
          fires: [
            'userdel deploy',
            'userdel -f deploy',
            'userdel -R /mnt/chroot deploy',
          ],
          misses: [
            'userdel -r deploy',
            'usermod -L deploy',
            'useradd -m deploy',
          ],
        ),
        (
          explanation: 'userdel -r also deletes the home directory.',
          severity: critical,
          fires: [
            'userdel -r deploy',
            'userdel -rf deploy',
            'userdel -fr deploy',
            'userdel --remove deploy',
            'sudo userdel -r deploy',
          ],
          misses: ['userdel deploy', 'userdel -f deploy'],
        ),
        (
          explanation:
              'Signals PID 1, the init process or a container\'s '
              'main process; this can reboot the host or stop the container.',
          severity: warning,
          fires: [
            'kill -9 1',
            'kill 1',
            'kill -TERM 1',
            'kill -s INT 1',
            'kill -s 1 1',
            'sudo kill -HUP 1',
          ],
          // A longer PID, a job spec, -1 as the signal, a signal or -l
          // operand, and tmux's hyphenated kill-* commands are not PID 1.
          misses: [
            'kill 1000',
            'kill -9 12345',
            'kill %1',
            'kill -1 1234',
            'kill -s 1 1234',
            'kill -n 1 1234',
            'kill -l 1',
            'tmux kill-session -t 1',
            'tmux kill-window -t 1',
          ],
        ),
      ];

      for (final rule in rules) {
        test('${rule.fires.first} is ${rule.severity.name}', () {
          for (final command in rule.fires) {
            final findings = [
              for (final f in DangerLinter.scan(command))
                (f.severity, f.explanation),
            ];
            expect(findings, [
              (rule.severity, rule.explanation),
            ], reason: command);
          }
          for (final command in rule.misses) {
            final explanations = [
              for (final f in DangerLinter.scan(command)) f.explanation,
            ];
            expect(
              explanations,
              isNot(contains(rule.explanation)),
              reason: command,
            );
          }
        });
      }

      test('leaves the benign commands of the design alone', () {
        const benign = [
          'docker compose up',
          'docker volume ls',
          'docker run -v /a:/b nginx',
          'docker system df',
          'systemctl status sshd',
          'crontab -l',
          'crontab -e',
          'ufw status',
          'nft list ruleset',
          'usermod -aG docker deploy',
          'useradd -m deploy',
          'kill 1000',
          'docker compose down',
        ];
        for (final command in benign) {
          expect(DangerLinter.scan(command), isEmpty, reason: command);
        }
      });

      test('keeps the existing rules separate', () {
        // Each command raises only the pre-existing rule it already hit.
        const existing = {
          'rm -rf /var/lib/docker': DangerSeverity.critical,
          'systemctl reboot': DangerSeverity.warning,
          'iptables -F': DangerSeverity.warning,
        };
        for (final MapEntry(key: command, value: severity)
            in existing.entries) {
          final findings = DangerLinter.scan(command);
          expect(findings, hasLength(1), reason: command);
          expect(findings.single.severity, severity, reason: command);
        }
      });
    });
  });

  group('PasteSanitizer', () {
    test('rejects multi-line paste (a newline would execute)', () {
      expect(
        () => PasteSanitizer.sanitize('echo hi\nrm -rf /'),
        throwsA(isA<UnsafePasteException>()),
      );
      expect(
        () => PasteSanitizer.sanitize('echo hi\n'),
        throwsA(isA<UnsafePasteException>()),
      );
    });

    test('strips control characters but keeps tabs and text', () {
      expect(PasteSanitizer.sanitize('echo hi\tthere'), 'echo hi\tthere');
    });

    test('sanitizeFirstLine collapses a block to its first command', () {
      expect(PasteSanitizer.sanitizeFirstLine('cd /tmp\nrm x\n'), 'cd /tmp');
    });

    test('sanitizeFirstLine treats a bare carriage return as a line break', () {
      expect(PasteSanitizer.sanitizeFirstLine('cd /tmp\rrm x'), 'cd /tmp');
    });
  });

  group('SecretRedactor', () {
    final r = SecretRedactor();

    test('masks API keys, tokens, and JWTs', () {
      expect(
        r.redact('export KEY=sk-ant-abcdefghij0123456789XYZ'),
        isNot(contains('sk-ant-abcdefghij0123456789XYZ')),
      );
      expect(
        r.redact('ghp_0123456789abcdef0123456789abcdef0123'),
        contains('«redacted»'),
      );
      expect(
        r.redact('OPENAI_API_KEY=sk-proj-abc_def-0123456789abcdefXYZ'),
        isNot(contains('sk-proj-abc_def-0123456789abcdefXYZ')),
      );
      expect(
        r.redact('github_pat_0123456789abcdef_0123456789abcdef'),
        contains('«redacted»'),
      );
      expect(r.redact('glpat-0123456789abcdefXYZ12'), contains('«redacted»'));
      final jwt = 'eyJhbGciOiJI.eyJzdWIiOiIxMjM0NTY3ODkw.SflKxwRJSMeKKF2QT4';
      expect(r.redact('token $jwt'), isNot(contains(jwt)));
    });

    test('masks private key blocks entirely', () {
      const key =
          '-----BEGIN OPENSSH PRIVATE KEY-----\nabc123secretkeymaterial\n-----END OPENSSH PRIVATE KEY-----';
      final out = r.redact('here is my key: $key done');
      expect(out, isNot(contains('secretkeymaterial')));
      expect(out, contains('here is my key'));
      expect(out, contains('done'));
    });

    test('masks inline password assignments but keeps the key name', () {
      final out = r.redact('DB_PASSWORD=sup3rSecretValue');
      expect(out, contains('DB_PASSWORD'));
      expect(out, isNot(contains('sup3rSecretValue')));
    });

    test('wouldRedact reports cleanly on benign text', () {
      expect(r.wouldRedact('just a normal sentence'), isFalse);
    });
  });
}
