import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/admin_controller.dart';
import '../controllers/monitoring_controller.dart';

/// A section that reads one host query of [serverId] through
/// [monitoring]; its state mixes in [HostReadSectionState].
abstract interface class HostReadSection implements StatefulWidget {
  MonitoringController get monitoring;
  String get serverId;
}

/// Reads [hostQuery] when the section shows, again on [readHost], and
/// afresh for another server or monitoring controller. Only the newest
/// read's answer lands, so a slow answer for an earlier server never
/// replaces a later one.
mixin HostReadSectionState<W extends HostReadSection> on State<W> {
  HostPayload? _read;
  bool _reading = false;

  /// Bumped per read, so only the newest answer lands.
  int _ticket = 0;

  /// The query this section shows.
  @protected
  HostQuerySpec get hostQuery;

  /// The newest read's answer; null until it lands.
  @protected
  HostPayload? get hostRead => _read;

  /// Whether a read is out.
  @protected
  bool get hostReading => _reading;

  @override
  void initState() {
    super.initState();
    unawaited(readHost());
  }

  @override
  void didUpdateWidget(W oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.monitoring == widget.monitoring) {
      return;
    }
    _read = null;
    unawaited(readHost());
  }

  /// Reads [hostQuery] again.
  @protected
  Future<void> readHost() async {
    final ticket = ++_ticket;
    if (mounted) setState(() => _reading = true);
    final result = await widget.monitoring.queryHost(
      widget.serverId,
      hostQuery,
    );
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _read = result.payload;
      _reading = false;
    });
  }
}

/// A section that reads a report of [serverId] in admin mode, on
/// request; its state mixes in [AdminReadSectionState].
abstract interface class AdminReadSection implements StatefulWidget {
  String get serverId;
}

/// Holds an admin-mode read of type [R] for the section's server: the
/// last read stays until the next one, and a server switch forgets it.
mixin AdminReadSectionState<W extends AdminReadSection, R> on State<W> {
  R? _report;

  /// The servers with a read out. A read outlives a switch away from its
  /// server, so a switch back must still see it and offer no second one.
  final _readingServers = <String>{};

  /// Asks [admin] for [serverId]'s report.
  @protected
  Future<R> readReport(AdminController admin, String serverId);

  /// The last read's report for this server; null before one.
  @protected
  R? get adminReport => _report;

  /// Whether a read for this server is out.
  @protected
  bool get adminReading => _readingServers.contains(widget.serverId);

  @override
  void didUpdateWidget(W oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId) return;
    _report = null;
  }

  /// Reads the report through [admin], unless a read is already out: a
  /// second tap before the button gives way would run the command twice.
  @protected
  Future<void> readAdmin(AdminController admin) async {
    if (adminReading) return;
    final serverId = widget.serverId;
    setState(() => _readingServers.add(serverId));
    final report = await readReport(admin, serverId);
    if (!mounted) return;
    setState(() {
      _readingServers.remove(serverId);
      if (serverId == widget.serverId) _report = report;
    });
  }
}
