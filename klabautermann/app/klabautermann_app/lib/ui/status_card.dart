import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'chart_strings.dart';
import 'charts/charts.dart';
import 'logs/log_export.dart' show showExportSheet;
import 'system_view.dart';

/// How many mounts a status card names, the fullest first.
const int _maxMountsShown = 5;

/// What a status card (PLT-08) says of a server: the last readings the
/// Overview shows, as plain lines. Each reading is optional, and a card
/// names only what was read. [serverName] and [identity]'s host name
/// appear only when the user chose to name the server, as cards shared
/// from such apps hide the host by default.
@immutable
final class StatusCard {
  const StatusCard({
    required this.readAt,
    this.serverName,
    this.core,
    this.fs,
    this.failedUnits,
    this.identity,
    this.uptimeWithheld = false,
    this.docker,
  });

  /// When the newest reading arrived; null before any.
  final DateTime? readAt;

  final String? serverName;
  final CoreResult? core;
  final FsSnapshot? fs;
  final List<SystemdUnit>? failedUnits;
  final IdentityResult? identity;

  /// Whether a container's `/proc/uptime` would give the host's (D50).
  final bool uptimeWithheld;
  final DockerSummary? docker;

  /// The card as lines; [named] adds the server's name and host name.
  List<String> lines(AppLocalizations l10n, {required bool named}) {
    final readAt = this.readAt;
    if (readAt == null) return [l10n.statusCardNothingRead];

    final strings = klabautermannChartStrings(l10n);
    String percent(double value) =>
        formatChartValue(value, ChartUnit.percent, strings);
    String bytes(int value) =>
        formatChartValue(value.toDouble(), ChartUnit.bytes, strings);

    final serverName = this.serverName;
    final hostname = identity?.hostname;
    final os = identity?.osPrettyName;
    final uptime = uptimeWithheld ? null : core?.uptime;
    final cpu = core?.cpu?.busy;
    final load = core?.load;
    final memory = core?.memory;
    final used = memory?.usedBytes;
    final total = memory?.totalBytes;
    final failed = failedUnits;
    final docker = this.docker;
    final fs = this.fs;
    final mounts = [
      if (fs != null)
        for (final mount in shownMounts(fs, showPseudo: false))
          if (mount.capacityPercent case final percent?)
            (mount.mountPoint, percent),
    ]..sort((a, b) => b.$2.compareTo(a.$2));

    return [
      l10n.statusCardHeading(readAt.toLocal()),
      if (named && serverName != null) l10n.statusCardServer(serverName),
      if (named && hostname != null) l10n.statusCardHostName(hostname),
      if (os != null) l10n.statusCardSystem(os),
      if (uptime != null) l10n.statusCardUptime(uptimeText(l10n, uptime)),
      if (cpu != null) l10n.statusCardCpu(percent(cpu)),
      if (load != null)
        l10n.statusCardLoad(load.load1, load.load5, load.load15),
      if (used != null && total != null && total > 0)
        l10n.statusCardMemory(
          bytes(used),
          bytes(total),
          percent(used * 100 / total),
        ),
      for (final (mountPoint, used) in mounts.take(_maxMountsShown))
        l10n.statusCardDisk(mountPoint, percent(used.toDouble())),
      if (failed != null) l10n.statusCardFailedUnits(failed.length),
      if (docker != null)
        l10n.statusCardContainers(
          docker.running,
          docker.running + docker.paused + docker.stopped,
        ),
      if (docker != null && docker.unhealthy > 0)
        l10n.statusCardUnhealthy(docker.unhealthy),
    ];
  }
}

/// [serverId]'s status card from [monitoring]'s last readings, as the
/// Overview shows them when the user asks for one.
StatusCard statusCardOf(
  MonitoringController monitoring,
  String serverId, {
  String? serverName,
}) {
  T? reading<T extends SampleResult>(SampleStream stream) =>
      switch (monitoring.lastReadingFor(serverId, stream).value?.result) {
        final T result => result,
        _ => null,
      };
  final docker = monitoring.docker;
  final containerList = docker.containersFor(serverId).value;
  final containers = containerList.containers;
  // The container counts are a reading too: a server with only Docker
  // read yet still gets a card, under that list's time.
  final times = [
    for (final stream in const [
      SampleStream.core,
      SampleStream.fs,
      SampleStream.failedUnits,
      SampleStream.identity,
    ])
      ?monitoring.lastReadingFor(serverId, stream).value?.at,
    if (containers != null) ?containerList.at,
  ];
  return StatusCard(
    readAt: times.isEmpty ? null : times.reduce((a, b) => a.isAfter(b) ? a : b),
    serverName: serverName,
    core: reading<CoreResult>(SampleStream.core),
    fs: reading<FsResult>(SampleStream.fs)?.fs,
    failedUnits: reading<FailedUnitsResult>(SampleStream.failedUnits)?.failed,
    identity: reading<IdentityResult>(SampleStream.identity),
    uptimeWithheld: withholdsHostFigure(
      monitoring.profileFor(serverId).value,
      SystemWideProcFile.uptime,
    ),
    docker: containers == null
        ? null
        : dockerSummary(
            containers,
            docker.imagesFor(serverId).value.images ?? const [],
            docker.diskUseFor(serverId).value.df,
          ),
  );
}

/// The Overview's way to a status card (PLT-08): the export sheet over
/// the card's lines, redacted unless the user includes secrets, with the
/// server left unnamed unless the user names it.
class StatusCardButton extends StatelessWidget {
  const StatusCardButton({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.serverName,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String serverName;

  void _open(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The readings as they are now: the card does not change under the
    // open sheet.
    final card = statusCardOf(monitoring, serverId, serverName: serverName);
    unawaited(
      showExportSheet(
        context,
        monitoring: monitoring,
        title: l10n.statusCardTitle,
        lines: card.lines(l10n, named: false),
        namedLines: card.lines(l10n, named: true),
        fileName: l10n.statusCardFileName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        onPressed: () => _open(context),
        icon: const Icon(Icons.ios_share),
        label: Text(l10n.statusCardAction),
      ),
    );
  }
}
