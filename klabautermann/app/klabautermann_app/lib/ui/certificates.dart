import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../controllers/tls_endpoints.dart';
import '../l10n/app_localizations.dart';
import 'system_panel.dart' show PanelNotice, PanelSection;

/// How close an expiry is before its line warns [E]: Let's Encrypt
/// renews 30 days ahead, so a certificate this close has missed renewals.
const kTlsExpirySoon = Duration(days: 14);

/// CRT-01's section of the System tab: the certificates the endpoints the
/// user listed for this server present, checked from this device, which
/// is the vantage point, without SSH. It checks when it shows, after an
/// edit and on request; a server switch checks the new server's.
class CertificatesSection extends StatefulWidget {
  const CertificatesSection({
    super.key,
    required this.monitoring,
    required this.serverId,
    this.now = DateTime.now,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// The clock the days left count from.
  final DateTime Function() now;

  @override
  State<CertificatesSection> createState() => _CertificatesSectionState();
}

class _CertificatesSectionState extends State<CertificatesSection> {
  /// The newest check's answers, by endpoint; null until one answers.
  Map<TlsEndpoint, TlsEndpointCheck>? _checks;
  bool _checking = false;
  bool _notSaved = false;

  /// Bumped per check, so only the newest answer lands.
  int _ticket = 0;

  TlsEndpoints get _endpoints => widget.monitoring.tlsEndpoints;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  @override
  void didUpdateWidget(CertificatesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.monitoring == widget.monitoring) {
      return;
    }
    _checks = null;
    _notSaved = false;
    unawaited(_check());
  }

  Future<void> _check() async {
    final ticket = ++_ticket;
    final endpoints = _endpoints.endpointsFor(widget.serverId);
    if (endpoints.isEmpty) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    if (mounted) setState(() => _checking = true);
    final checks = await widget.monitoring.checkTlsEndpoints(endpoints);
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _checking = false;
      _checks = {for (final check in checks ?? const []) check.endpoint: check};
    });
  }

  Future<void> _edit() async {
    final serverId = widget.serverId;
    final edited = await showDialog<List<TlsEndpoint>>(
      context: context,
      builder: (context) =>
          _EndpointsDialog(initial: _endpoints.endpointsFor(serverId)),
    );
    if (edited == null || !mounted || serverId != widget.serverId) return;
    var saved = true;
    try {
      await _endpoints.setEndpoints(serverId, edited);
    } on Object {
      // The list holds for this run; the notice says it was not kept.
      saved = false;
    }
    if (!mounted || serverId != widget.serverId) return;
    setState(() => _notSaved = !saved);
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final endpoints = _endpoints.endpointsFor(widget.serverId);
    final checks = _checks;

    return PanelSection(
      title: l10n.systemCertificatesTitle,
      children: [
        if (endpoints.isEmpty) Text(l10n.systemCertificatesNone),
        if (_notSaved)
          PanelNotice(
            icon: Icons.error_outline,
            text: l10n.systemCertificatesNotSaved,
          ),
        for (final endpoint in endpoints)
          _EndpointLine(
            endpoint: endpoint,
            check: checks?[endpoint],
            checking: _checking,
            now: widget.now().toUtc(),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (endpoints.isNotEmpty)
              OutlinedButton(
                onPressed: _checking ? null : () => unawaited(_check()),
                child: Text(l10n.systemCertificatesCheck),
              ),
            OutlinedButton(
              onPressed: () => unawaited(_edit()),
              child: Text(l10n.systemCertificatesEdit),
            ),
          ],
        ),
      ],
    );
  }
}

/// One endpoint: its label, then when its certificate expires and who
/// issued it, or why the check read none, read as one node.
class _EndpointLine extends StatelessWidget {
  const _EndpointLine({
    required this.endpoint,
    required this.check,
    required this.checking,
    required this.now,
  });

  final TlsEndpoint endpoint;
  final TlsEndpointCheck? check;
  final bool checking;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final check = this.check;
    final certificate = check?.certificate;
    final left = certificate?.notAfter.difference(now);
    final warn =
        check?.failure != null ||
        (check != null && !check.trusted) ||
        (left != null && left < kTlsExpirySoon);

    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(
            check == null
                ? Icons.hourglass_empty
                : warn
                ? Icons.warning_amber
                : Icons.verified_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(endpoint.label, style: theme.textTheme.bodyLarge),
                if (check == null)
                  Text(
                    checking
                        ? l10n.systemCertificatesChecking
                        : l10n.systemCertificatesNotChecked,
                    style: muted,
                  )
                else if (check.failure case final failure?) ...[
                  Text(l10n.systemCertificatesFailed(failure.name)),
                  if (check.detail case final detail?)
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                ] else if (certificate != null) ...[
                  Text(
                    left!.isNegative
                        ? l10n.systemCertificatesExpired(
                            certificate.notAfter.toLocal(),
                          )
                        : l10n.systemCertificatesExpires(
                            certificate.notAfter.toLocal(),
                            left.inDays,
                          ),
                  ),
                  if (!check.trusted) Text(l10n.systemCertificatesUntrusted),
                  Text(
                    l10n.systemCertificatesIssuer(certificate.issuer),
                    style: muted,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for the endpoints to check, one per line.
class _EndpointsDialog extends StatefulWidget {
  const _EndpointsDialog({required this.initial});

  final List<TlsEndpoint> initial;

  @override
  State<_EndpointsDialog> createState() => _EndpointsDialogState();
}

class _EndpointsDialogState extends State<_EndpointsDialog> {
  late final _text = TextEditingController(
    text: [for (final endpoint in widget.initial) endpoint.label].join('\n'),
  );
  TlsEndpointsProblem? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final (:endpoints, :problem) = parseTlsEndpoints(_text.text);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.pop(context, endpoints);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.systemCertificatesEditTitle),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _text,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            helperText: l10n.systemCertificatesHelper(kTlsEndpointsMax),
            helperMaxLines: 3,
            errorText: switch (_problem) {
              null => null,
              final problem => l10n.systemCertificatesProblem(
                problem.name,
                kTlsEndpointsMax,
              ),
            },
            errorMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.systemCertificatesCancel),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(l10n.systemCertificatesSave),
        ),
      ],
    );
  }
}
