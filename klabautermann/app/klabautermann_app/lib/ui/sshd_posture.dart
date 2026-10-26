import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/admin_controller.dart';
import '../l10n/app_localizations.dart';
import 'admin_mode_chip.dart' show AdminScope;
import 'system_panel.dart' show PanelNotice, PanelSection;

/// Builds one labelled fact, with a note under it where one is given.
typedef SshdFactBuilder =
    Widget Function(String label, String? value, {String? note});

/// SEC-01's section of the System tab: the SSH server's effective
/// settings for the app's own connection, read on request in admin mode,
/// since `sshd -T` loads the host keys. It says whether sshd lets the
/// Docker transport forward its socket (03 §5.3). The last read stays
/// until the next one, and a server switch forgets it.
class SshdPostureSection extends StatefulWidget {
  const SshdPostureSection({
    super.key,
    required this.serverId,
    required this.fact,
  });

  final String serverId;
  final SshdFactBuilder fact;

  @override
  State<SshdPostureSection> createState() => _SshdPostureSectionState();
}

class _SshdPostureSectionState extends State<SshdPostureSection> {
  SshdPostureReport? _report;
  bool _reading = false;

  @override
  void didUpdateWidget(SshdPostureSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId) return;
    _report = null;
    _reading = false;
  }

  Future<void> _read(AdminController admin) async {
    if (_reading) return;
    final serverId = widget.serverId;
    setState(() => _reading = true);
    final report = await admin.readSshdPosture(serverId);
    if (!mounted || serverId != widget.serverId) return;
    setState(() {
      _report = report;
      _reading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final admin = AdminScope.maybeOf(context);
    final adminOn =
        admin?.stateFor(widget.serverId)?.phase == AdminModePhase.on;
    final report = _report;
    final failure = report?.failure;
    final posture = report?.posture;

    return PanelSection(
      title: l10n.systemSshdTitle,
      children: [
        if (failure != null)
          PanelNotice(
            icon: Icons.error_outline,
            text: l10n.systemSshdFailed(failure.name),
            detail: report?.detail,
          ),
        if (posture != null) ..._settings(l10n, posture),
        if (_reading)
          Text(l10n.systemSshdReading)
        else if (!adminOn || admin == null)
          Text(l10n.systemSshdAdminNeeded)
        else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              onPressed: () => unawaited(_read(admin)),
              child: Text(
                report == null ? l10n.systemSshdRead : l10n.systemSshdReadAgain,
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _settings(AppLocalizations l10n, SshdPosture posture) {
    final fact = widget.fact;
    String? onOff(bool? value) =>
        value == null ? null : l10n.systemSshdEnabled(value.toString());
    String? joined(List<Object> values) =>
        values.isEmpty ? null : values.join(', ');
    final blocks = posture.dockerBlocks;

    return [
      switch (posture.match) {
        SshdMatchContext.connection => null,
        SshdMatchContext.remote => PanelNotice(
          icon: Icons.info_outline,
          text: l10n.systemSshdMatchRemote,
        ),
        SshdMatchContext.none => PanelNotice(
          icon: Icons.info_outline,
          text: l10n.systemSshdMatchNone,
        ),
      },
      fact(l10n.systemSshdPorts, joined(posture.ports)),
      fact(l10n.systemSshdListen, joined(posture.listenAddresses)),
      fact(l10n.systemSshdRootLogin, switch (posture.permitRootLogin) {
        final value? => l10n.systemSshdRoot(value.name),
        null => null,
      }),
      fact(l10n.systemSshdPassword, onOff(posture.passwordAuthentication)),
      fact(l10n.systemSshdKeyboard, onOff(posture.keyboardInteractive)),
      fact(l10n.systemSshdPubkey, onOff(posture.pubkeyAuthentication)),
      if (posture.authenticationMethods case final methods?)
        fact(l10n.systemSshdMethods, methods),
      fact(l10n.systemSshdHostKeys, joined(posture.hostKeyTypes)),
      fact(l10n.systemSshdUserKeys, joined(posture.userKeyTypes)),
      fact(l10n.systemSshdMaxSessions, posture.maxSessions?.toString()),
      fact(
        l10n.systemSshdTcpForwarding,
        _forwarding(l10n, posture.allowTcpForwarding),
      ),
      fact(
        l10n.systemSshdSocketForwarding,
        _forwarding(l10n, posture.allowStreamLocalForwarding),
      ),
      fact(l10n.systemSshdPermitOpen, posture.permitOpen),
      fact(
        l10n.systemSshdDocker,
        blocks.isEmpty
            ? l10n.systemSshdDockerAllowed
            : l10n.systemSshdDockerBlocked(
                blocks.map((block) => block.keyword).join(', '),
              ),
        note: l10n.systemSshdDockerNote,
      ),
    ].nonNulls.toList();
  }

  static String? _forwarding(AppLocalizations l10n, SshdForwarding? value) =>
      value == null ? null : l10n.systemSshdForwarding(value.name);
}
