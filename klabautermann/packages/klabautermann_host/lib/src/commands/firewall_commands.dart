part of 'commands.dart';

/// [HostCommands.firewall]'s section markers, each printed only where its
/// tool is installed; firewalld's carries its state.
const kFirewallUfwMarker = '== ufw';
const kFirewallFirewalldMarker = '== firewalld';
const kFirewallNftMarker = '== nft';
const kFirewallIptablesMarker = '== iptables';
const kFirewallIp6tablesMarker = '== ip6tables';

/// The most lines [HostCommands.firewall] keeps of each tool's output [E].
const kFirewallLinesKept = 4000;
