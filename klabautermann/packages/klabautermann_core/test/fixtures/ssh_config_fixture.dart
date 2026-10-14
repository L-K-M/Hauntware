/// An OpenSSH client config exercising what Séance's `SshConfigImporter`
/// reads, drops and ignores (FL-02). The comments say what each block
/// should produce; [sshConfigFixtureEntries] and
/// [sshConfigFixtureSkipped] are the expected totals.
const String sshConfigFixture = r'''
# Defaults before the first Host block: ssh applies them everywhere, the
# importer drops them, and the top-level Include is not followed.
User everyone
Include ~/.ssh/config.d/*

Host web-1
  HostName web-1.example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/id_ed25519

# Several patterns: the first non-wildcard one names the entry.
Host db-1 *.db.internal
  HostName 10.0.0.4   # trailing comment

# No HostName: ssh connects to the alias itself. `Key=value` form.
Host bastion
  User=admin
  ProxyJump jump.example

# Wildcard-only blocks are defaults, not hosts (negations count).
Host *
  ServerAliveInterval 30

Host *.corp !secret.corp
  User corp

# A conditional block: its directives are ignored.
Match host web-1 exec "true"
  User matched

# An Include inside a host block is not followed either.
Host legacy
  Include legacy.conf
  HostName legacy.example.com

# A port no endpoint can use: skipped and counted.
Host broken-port
  Port 70000

# A second block for a taken alias: skipped and counted, not merged.
Host web-1
  User someone-else

Host v6
  HostName 2001:db8::1
''';

/// Hosts [sshConfigFixture] imports, in file order.
const List<String> sshConfigFixtureEntries = [
  'web-1',
  'db-1',
  'bastion',
  'legacy',
  'v6',
];

/// Blocks [sshConfigFixture] skips: `broken-port` and the second `web-1`.
const int sshConfigFixtureSkipped = 2;
