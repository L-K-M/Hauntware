/// The parser for NET-06's firewall view (03 §7.4), as
/// [HostCommands.firewall] prints it: ufw's status, firewalld's zones,
/// nftables' ruleset and the iptables chains.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show
        HostCommands,
        kFirewallFirewalldMarker,
        kFirewallIp6tablesMarker,
        kFirewallIptablesMarker,
        kFirewallNftMarker,
        kFirewallUfwMarker;

/// One ufw rule as `ufw status` lists it.
@immutable
final class UfwRule {
  const UfwRule({required this.to, required this.action, required this.from});

  /// `22/tcp`, `80,443/tcp (Nginx Full)`, `Anywhere on eth0`.
  final String to;

  /// `ALLOW IN`, `DENY OUT`, `LIMIT IN`, `REJECT IN`.
  final String action;
  final String from;
}

/// `ufw status verbose`.
@immutable
final class UfwStatus {
  UfwStatus({
    required this.active,
    this.incoming,
    this.outgoing,
    this.routed,
    Iterable<UfwRule> rules = const [],
  }) : rules = List.unmodifiable(rules);

  final bool active;

  /// Each direction's default policy as ufw names it: `deny`, `allow`,
  /// `reject` or `disabled`; null where ufw printed none.
  final String? incoming, outgoing, routed;
  final List<UfwRule> rules;
}

/// One firewalld zone.
@immutable
final class FirewalldZone {
  FirewalldZone({
    required this.name,
    required this.active,
    required this.isDefault,
    this.target,
    Iterable<String> interfaces = const [],
    Iterable<String> sources = const [],
    Iterable<String> services = const [],
    Iterable<String> ports = const [],
  }) : interfaces = List.unmodifiable(interfaces),
       sources = List.unmodifiable(sources),
       services = List.unmodifiable(services),
       ports = List.unmodifiable(ports);

  final String name;

  /// Whether an interface or source is bound to it.
  final bool active;
  final bool isDefault;

  /// `default`, `ACCEPT`, `DROP` or `%%REJECT%%`.
  final String? target;
  final List<String> interfaces, sources, services, ports;
}

/// firewalld's state and, while it runs, its zones.
@immutable
final class FirewalldStatus {
  FirewalldStatus({
    required this.running,
    Iterable<FirewalldZone> zones = const [],
  }) : zones = List.unmodifiable(zones);

  final bool running;
  final List<FirewalldZone> zones;
}

/// One chain, of nftables or iptables.
@immutable
final class FirewallChain {
  const FirewallChain({
    required this.table,
    required this.name,
    required this.rules,
    this.family,
    this.hook,
    this.policy,
  });

  /// nftables' family (`inet`, `ip`, `ip6`, `bridge`); null for iptables,
  /// whose family is its tool's.
  final String? family;
  final String table;
  final String name;

  /// nftables' hook (`input`, `forward`, `output`, ...); null for a
  /// regular chain and for iptables.
  final String? hook;

  /// The policy of a base chain, lower case: `accept`, `drop`; null for a
  /// regular chain, which has none.
  final String? policy;
  final int rules;
}

/// What [HostCommands.firewall] found. A tool that is not installed is
/// null; [nftables] and the iptables chains read empty where the tool
/// is installed but holds no rules.
@immutable
final class FirewallRead {
  FirewallRead({
    this.ufw,
    this.firewalld,
    List<FirewallChain>? nftables,
    List<FirewallChain>? iptables,
    List<FirewallChain>? ip6tables,
  }) : nftables = nftables == null ? null : List.unmodifiable(nftables),
       iptables = iptables == null ? null : List.unmodifiable(iptables),
       ip6tables = ip6tables == null ? null : List.unmodifiable(ip6tables);

  final UfwStatus? ufw;
  final FirewalldStatus? firewalld;
  final List<FirewallChain>? nftables;
  final List<FirewallChain>? iptables;
  final List<FirewallChain>? ip6tables;

  /// Whether no firewall tool is installed.
  bool get noTool =>
      ufw == null &&
      firewalld == null &&
      nftables == null &&
      iptables == null &&
      ip6tables == null;
}

/// The read in [raw], or null when it is not the read's output: the
/// output must be empty or start with a section marker.
FirewallRead? parseFirewall(String raw) {
  final sections = <String, List<String>>{};
  String? current;
  String? firewalldState;
  for (final line in raw.split('\n')) {
    final marker = switch (line.trim()) {
      kFirewallUfwMarker => kFirewallUfwMarker,
      kFirewallNftMarker => kFirewallNftMarker,
      kFirewallIptablesMarker => kFirewallIptablesMarker,
      kFirewallIp6tablesMarker => kFirewallIp6tablesMarker,
      final text when text.startsWith('$kFirewallFirewalldMarker ') =>
        kFirewallFirewalldMarker,
      _ => null,
    };
    if (marker != null) {
      current = marker;
      sections[marker] = [];
      if (marker == kFirewallFirewalldMarker) {
        firewalldState = line
            .trim()
            .substring(kFirewallFirewalldMarker.length)
            .trim();
      }
      continue;
    }
    if (current == null) {
      if (line.trim().isEmpty) continue;
      return null;
    }
    sections[current]!.add(line);
  }

  return FirewallRead(
    ufw: switch (sections[kFirewallUfwMarker]) {
      final lines? => _ufw(lines),
      null => null,
    },
    firewalld: switch (sections[kFirewallFirewalldMarker]) {
      final lines? => FirewalldStatus(
        running: firewalldState == 'running',
        zones: firewalldState == 'running' ? _zones(lines) : const [],
      ),
      null => null,
    },
    nftables: switch (sections[kFirewallNftMarker]) {
      final lines? => _nft(lines.join('\n')),
      null => null,
    },
    iptables: switch (sections[kFirewallIptablesMarker]) {
      final lines? => _iptables(lines),
      null => null,
    },
    ip6tables: switch (sections[kFirewallIp6tablesMarker]) {
      final lines? => _iptables(lines),
      null => null,
    },
  );
}

final _columns = RegExp(r'\s{2,}');
final _defaults = RegExp(r'(\w+) \((\w+)\)');

UfwStatus _ufw(List<String> lines) {
  var active = false;
  final defaults = <String, String>{};
  final rules = <UfwRule>[];
  var inTable = false;
  for (final line in lines) {
    final text = line.trim();
    if (text.startsWith('Status:')) {
      active = text.substring('Status:'.length).trim() == 'active';
    } else if (text.startsWith('Default:')) {
      for (final match in _defaults.allMatches(text)) {
        defaults[match[2]!] = match[1]!;
      }
    } else if (text.startsWith('--')) {
      inTable = true;
    } else if (inTable && text.isNotEmpty) {
      final cells = text.split(_columns);
      if (cells.length >= 3) {
        rules.add(UfwRule(to: cells[0], action: cells[1], from: cells[2]));
      }
    }
  }
  return UfwStatus(
    active: active,
    incoming: defaults['incoming'],
    outgoing: defaults['outgoing'],
    routed: defaults['routed'],
    rules: rules,
  );
}

final _zoneHeader = RegExp(r'^(\S+)(?:\s+\(([^)]*)\))?\s*$');

List<FirewalldZone> _zones(List<String> lines) {
  final zones = <FirewalldZone>[];
  String? name;
  var flags = const <String>{};
  var fields = <String, String>{};

  void flush() {
    final zone = name;
    if (zone == null) return;
    List<String> words(String key) => [
      for (final word in (fields[key] ?? '').split(RegExp(r'\s+')))
        if (word.isNotEmpty) word,
    ];
    zones.add(
      FirewalldZone(
        name: zone,
        active: flags.contains('active'),
        isDefault: flags.contains('default'),
        target: fields['target'],
        interfaces: words('interfaces'),
        sources: words('sources'),
        services: words('services'),
        ports: words('ports'),
      ),
    );
  }

  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    if (!line.startsWith(' ') && !line.startsWith('\t')) {
      final match = _zoneHeader.firstMatch(line);
      if (match == null) continue;
      flush();
      name = match[1];
      flags = {
        for (final flag in (match[2] ?? '').split(','))
          if (flag.trim().isNotEmpty) flag.trim(),
      };
      fields = {};
      continue;
    }
    final colon = line.indexOf(':');
    if (colon < 0 || name == null) continue;
    fields[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
  }
  flush();
  return zones;
}

/// The chains of `nft -j list ruleset`, with their rule counts; a cut or
/// unreadable answer reads as none.
List<FirewallChain> _nft(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return const [];
  }
  if (json case {'nftables': final List<Object?> items}) {
    final chains = <(String, String, String), Map<String, Object?>>{};
    final counts = <(String, String, String), int>{};
    for (final item in items) {
      switch (item) {
        case {'chain': final Map<String, Object?> chain}:
          if (chain case {
            'family': final String family,
            'table': final String table,
            'name': final String name,
          }) {
            chains[(family, table, name)] = chain;
          }
        case {
          'rule': {
            'family': final String family,
            'table': final String table,
            'chain': final String chain,
          },
        }:
          final key = (family, table, chain);
          counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    return [
      for (final MapEntry(key: (family, table, name), value: chain)
          in chains.entries)
        FirewallChain(
          family: family,
          table: table,
          name: name,
          hook: switch (chain['hook']) {
            final String hook => hook,
            _ => null,
          },
          policy: switch (chain['policy']) {
            final String policy => policy,
            _ => null,
          },
          rules: counts[(family, table, name)] ?? 0,
        ),
    ];
  }
  return const [];
}

/// The chains of `iptables-save`: `*table`, `:CHAIN POLICY [p:b]` and
/// `-A CHAIN ...` lines.
List<FirewallChain> _iptables(List<String> lines) {
  final chains = <(String, String), String?>{};
  final counts = <(String, String), int>{};
  String? table;
  for (final line in lines) {
    final text = line.trim();
    if (text.startsWith('*')) {
      table = text.substring(1);
    } else if (table != null && text.startsWith(':')) {
      final words = text.substring(1).split(' ');
      final policy = words.length > 1 && words[1] != '-'
          ? words[1].toLowerCase()
          : null;
      chains[(table, words.first)] = policy;
    } else if (table != null && text.startsWith('-A ')) {
      final chain = text.substring(3).split(' ').first;
      counts[(table, chain)] = (counts[(table, chain)] ?? 0) + 1;
    }
  }
  return [
    for (final MapEntry(key: (table, name), value: policy) in chains.entries)
      FirewallChain(
        table: table,
        name: name,
        policy: policy,
        rules: counts[(table, name)] ?? 0,
      ),
  ];
}
