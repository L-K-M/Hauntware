/// An OpenSSH client config exercising what the FL-02 import reads, drops
/// and ignores. The comments say what each block should produce;
/// [sshConfigFixtureEntries] and [sshConfigFixtureSkipped] are the
/// expected totals.
const String sshConfigFixture = r'''
# Lines before the first Host block apply to every host; this one sets
# nothing the engine maps.
ServerAliveInterval 15

Host web-1
  HostName web-1.example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/id_ed25519

# Several patterns: each non-wildcard one names an entry, here only db-1.
Host db-1 *.db.internal
  HostName 10.0.0.4   # trailing comment

# No HostName: ssh connects to the alias itself. `Key=value` form.
Host bastion
  User=admin
  ProxyJump jump.example

# Wildcard-only blocks name no host, and these set nothing for the hosts
# here: the first nothing the engine maps, the second matches none.
Host *
  ServerAliveInterval 30

Host *.corp !secret.corp
  User corp

# `host` compares the HostName read so far, so this applies to no host
# here, and `exec` is not run once a criterion fails.
Match host web-1 exec "true"
  User matched

Host legacy
  HostName legacy.example.com

# A port no endpoint can use: skipped and counted.
Host broken-port
  Port 70000

# A second block for web-1 adds only what the first left unset: its
# ProxyJump, not its User.
Host web-1
  User someone-else
  ProxyJump none

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

/// Hosts [sshConfigFixture] skips: `broken-port`.
const int sshConfigFixtureSkipped = 1;
