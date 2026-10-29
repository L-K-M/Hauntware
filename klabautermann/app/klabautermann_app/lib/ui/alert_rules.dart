import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show UndoDirection;
import 'package:ghost_ui/ghost_ui.dart'
    show GhostUndoableChange, showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/alert_rules_controller.dart';
import '../controllers/fleet_controller.dart';
import '../l10n/app_localizations.dart';
import 'alert_notifications.dart';
import 'alerts.dart';
import 'app_undo.dart';
import 'server_editing.dart';

/// Hands the [AlertRulesController] to the server header and the alert
/// center; without one, as in tests that leave rules out, neither offers
/// the rules page.
class AlertRulesScope extends InheritedNotifier<AlertRulesController> {
  const AlertRulesScope({
    super.key,
    required AlertRulesController rules,
    required super.child,
  }) : super(notifier: rules);

  static AlertRulesController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AlertRulesScope>()?.notifier;
}

/// Opens the alert rules page: the rules that apply to [server], or every
/// rule when null. Does nothing without an [AlertRulesScope].
Future<void> openAlertRules(
  BuildContext context, {
  required FleetController fleet,
  FleetServer? server,
}) async {
  final rules = AlertRulesScope.maybeOf(context);
  if (rules == null) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          AlertRulesPage(rules: rules, fleet: fleet, server: server),
    ),
  );
}

/// The server header's way to its alert rules (ALR-01).
class AlertRulesButton extends StatelessWidget {
  const AlertRulesButton({
    super.key,
    required this.server,
    required this.fleet,
  });

  final FleetServer server;
  final FleetController fleet;

  @override
  Widget build(BuildContext context) {
    if (AlertRulesScope.maybeOf(context) == null) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: const Icon(Icons.notifications_outlined),
      tooltip: AppLocalizations.of(context).alertRulesTitle,
      onPressed: () =>
          unawaited(openAlertRules(context, fleet: fleet, server: server)),
    );
  }
}

/// Whether [rule] applies to [server] (03 §7.19): a `server` rule naming
/// it, a `group` rule naming its group, or an `all` rule.
bool alertRuleAppliesTo(SyncedRule rule, FleetServer server) =>
    switch (rule.rule.scope) {
      RuleScope.server => rule.target == server.id,
      RuleScope.group => rule.target != null && rule.target == server.group,
      RuleScope.all => true,
    };

/// The words for a failed rule write: the engine's refusal, or its
/// stopping.
String alertRuleFailureText(AppLocalizations l10n, Object error) =>
    switch (error) {
      AlertRuleNotSavedException(failure: null) => l10n.alertRuleEngineStopped,
      AlertRuleNotSavedException(:final failure?, :final detail) =>
        l10n.alertRuleRefused(failure.name, detail ?? ''),
      _ => l10n.alertRuleRefused(CatalogWriteFailure.other.name, '$error'),
    };

/// [duration] in whole minutes, or in seconds when it is not.
String alertRuleDurationText(AppLocalizations l10n, Duration duration) =>
    duration.inSeconds % Duration.secondsPerMinute == 0
    ? l10n.alertRuleMinutes(duration.inMinutes)
    : l10n.alertRuleSeconds(duration.inSeconds);

/// [value] of [metric] as a rule shows it; a metric this version does not
/// know shows a plain number.
String _thresholdText(AppLocalizations l10n, String metric, double value) =>
    alertValueText(l10n, metric, value) ?? l10n.overviewLoadValue(value);

/// The alert rules page (ALR-01, 03 §7.19): the account's rules, or those
/// that apply to [server], each with the coverage limit (Y3), and, while
/// an account is enrolled, the editor that adds, changes and deletes
/// them. Rules are `rule` records, so they sync to every device.
class AlertRulesPage extends StatelessWidget {
  const AlertRulesPage({
    super.key,
    required this.rules,
    required this.fleet,
    this.server,
  });

  final AlertRulesController rules;
  final FleetController fleet;

  /// The server the page was opened from; null for every rule.
  final FleetServer? server;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final canEdit = ServerEditingScope.maybeOf(context)?.enabled ?? false;
    return ListenableBuilder(
      listenable: Listenable.merge([rules, fleet]),
      builder: (context, _) {
        final server = this.server;
        final shown = [
          for (final rule in rules.rules)
            if (server == null || alertRuleAppliesTo(rule, server)) rule,
        ];
        return Scaffold(
          appBar: AppBar(title: Text(l10n.alertRulesTitle)),
          floatingActionButton: canEdit
              ? FloatingActionButton.extended(
                  onPressed: () => unawaited(_edit(context, null)),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.alertRuleAdd),
                )
              : null,
          body: ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 8),
                child: Text(
                  l10n.alertsCoverage,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const AlertNotificationsSwitch(),
              if (!canEdit)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
                  child: Text(l10n.alertRulesNeedSync),
                ),
              if (shown.isEmpty)
                ListTile(
                  title: Text(
                    server == null
                        ? l10n.alertRulesEmpty
                        : l10n.alertRulesEmptyServer,
                  ),
                ),
              for (final rule in shown) _row(context, rule, canEdit: canEdit),
            ],
          ),
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    SyncedRule synced, {
    required bool canEdit,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rule = synced.rule;
    final severity = alertRuleSeverity(rule);
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final raised = [
      _scopeText(l10n, synced),
      l10n.alertSeverity(severity.name),
      if (rule.raise.duration > Duration.zero)
        l10n.alertRuleFor(alertRuleDurationText(l10n, rule.raise.duration)),
    ].join(l10n.fleetRowPartSeparator);
    final cleared = [
      l10n.alertRuleClears(
        rule.op.name,
        _thresholdText(l10n, rule.metric, rule.clear.value),
      ),
      if (rule.clear.duration > Duration.zero)
        l10n.alertRuleFor(alertRuleDurationText(l10n, rule.clear.duration)),
    ].join(l10n.fleetRowPartSeparator);
    return ListTile(
      key: ValueKey(synced.id),
      leading: Icon(
        alertSeverityIcon(severity),
        color: alertSeverityColor(context, severity),
      ),
      title: Text(
        l10n.alertRuleCondition(
          rule.op.name,
          alertMetricName(l10n, rule.metric),
          _thresholdText(l10n, rule.metric, rule.raise.value),
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(raised),
          Text(cleared),
          // Every rule row states the coverage limit (03 §7.19, Y3).
          if (rule.evalScope == RuleEvalScope.client)
            Text(l10n.alertsCoverage, style: secondary),
        ],
      ),
      isThreeLine: true,
      onTap: canEdit ? () => unawaited(_edit(context, synced)) : null,
      trailing: canEdit
          ? IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.alertRuleDelete,
              onPressed: () => unawaited(_delete(context, synced)),
            )
          : null,
    );
  }

  String _scopeText(AppLocalizations l10n, SyncedRule synced) {
    final target = synced.target;
    return switch (synced.rule.scope) {
      RuleScope.server => l10n.alertRuleScopeServer(
        fleet.servers
                .where((server) => server.id == target)
                .firstOrNull
                ?.displayName ??
            target ??
            '',
      ),
      RuleScope.group => l10n.alertRuleScopeGroup(target ?? ''),
      RuleScope.all => l10n.alertRuleScopeAll,
    };
  }

  Future<void> _edit(BuildContext context, SyncedRule? existing) async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context);
    final edited = await showDialog<AlertRuleEdit>(
      context: context,
      builder: (_) => AlertRuleEditor(
        existing: existing,
        server: server,
        serverName: (id) =>
            fleet.servers.where((s) => s.id == id).firstOrNull?.displayName ??
            id,
      ),
    );
    if (edited == null || !context.mounted) return;
    try {
      await putAlertRuleUndoably(context, rules, edited, existing: existing);
    } on Object catch (error) {
      if (overlay.mounted) {
        showTopToast(overlay, message: alertRuleFailureText(l10n, error));
      }
    }
  }

  /// The rule goes at once and Undo brings it back — the notice's, or the
  /// app's undo shortcut (⌘Z, Ctrl+Z), as Finder and Notes delete.
  Future<void> _delete(BuildContext context, SyncedRule rule) async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context);
    final history = UndoHistoryScope.maybeOf(context);
    late final GhostUndoableChange? change;
    try {
      change = await deleteAlertRuleUndoably(context, rules, rule);
    } on Object catch (error) {
      if (overlay.mounted) {
        showTopToast(overlay, message: alertRuleFailureText(l10n, error));
      }
      return;
    }
    if (!overlay.mounted) return;
    final recorded = change;
    showTopToast(
      overlay,
      message: l10n.alertRuleDeleted,
      actionLabel: recorded == null || history == null ? null : l10n.editUndo,
      onAction: recorded == null || history == null
          ? null
          : () {
              if (overlay.mounted && history.isNextUndo(recorded)) {
                unawaited(
                  stepUndoHistory(
                    overlay,
                    history,
                    direction: UndoDirection.undo,
                  ),
                );
              }
            },
    );
  }
}

/// What the rule editor returns: the rule and the server or group its
/// scope names.
typedef AlertRuleEdit = ({ThresholdRule rule, String? target});

/// The rule editor (ALR-01): a metric, a comparison, the raise and clear
/// thresholds with how long each must hold (ALR-16's hysteresis), a
/// severity and the servers it applies to. A new rule from a server
/// starts on that server.
class AlertRuleEditor extends StatefulWidget {
  const AlertRuleEditor({
    super.key,
    this.existing,
    this.server,
    required this.serverName,
  });

  final SyncedRule? existing;
  final FleetServer? server;

  /// A server's name by its id, for a `server` rule's scope.
  final String Function(String serverId) serverName;

  @override
  State<AlertRuleEditor> createState() => _AlertRuleEditorState();
}

class _AlertRuleEditorState extends State<AlertRuleEditor> {
  static const _defaultRaise = 90.0, _defaultClear = 80.0;

  final _form = GlobalKey<FormState>();
  late String _metric;
  late ThresholdOp _op;
  late AlertSeverity _severity;
  late (RuleScope, String?) _scope;

  /// The metric and scope the editor opened with, which its menus keep
  /// offering after a change, so a rule's own can be chosen again.
  late final String _ownMetric;
  late final (RuleScope, String?) _ownScope;
  late final TextEditingController _raise, _raiseFor, _clear, _clearFor;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final rule = existing?.rule;
    _metric = rule?.metric ?? AlertMetric.cpuBusy.id;
    _op = rule?.op ?? ThresholdOp.greaterThan;
    _severity = rule == null ? AlertSeverity.warning : alertRuleSeverity(rule);
    _scope = switch ((existing, widget.server)) {
      (final existing?, _) => (existing.rule.scope, existing.target),
      (null, final server?) => (RuleScope.server, server.id),
      (null, null) => (RuleScope.all, null),
    };
    _ownMetric = _metric;
    _ownScope = _scope;
    _raise = TextEditingController(
      text: _numberText(rule?.raise.value ?? _defaultRaise),
    );
    _clear = TextEditingController(
      text: _numberText(rule?.clear.value ?? _defaultClear),
    );
    _raiseFor = TextEditingController(
      text: _minutesText(rule?.raise.duration ?? Duration.zero),
    );
    _clearFor = TextEditingController(
      text: _minutesText(rule?.clear.duration ?? Duration.zero),
    );
    // The Save button stays enabled only while every field is valid
    // (ALR-01), so a change recomputes without showing errors.
    for (final field in [_raise, _raiseFor, _clear, _clearFor]) {
      field.addListener(_refreshValidity);
    }
  }

  @override
  void dispose() {
    _raise.dispose();
    _clear.dispose();
    _raiseFor.dispose();
    _clearFor.dispose();
    super.dispose();
  }

  static String _numberText(double value) => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toString();

  static String _minutesText(Duration duration) =>
      _numberText(duration.inMilliseconds / Duration.millisecondsPerMinute);

  /// A number as typed, with a comma for the decimal point too.
  static double? _parse(String text) {
    final value = double.tryParse(text.trim().replaceAll(',', '.'));
    return value != null && value.isFinite ? value : null;
  }

  bool get _percent => switch (AlertMetric.byId(_metric)) {
    AlertMetric.loadPerCore || null => false,
    _ => true,
  };

  bool get _above => switch (_op) {
    ThresholdOp.greaterThan || ThresholdOp.greaterOrEqual => true,
    ThresholdOp.lessThan || ThresholdOp.lessOrEqual => false,
  };

  String? _validateValue(AppLocalizations l10n, String? text) {
    final value = _parse(text ?? '');
    if (value == null) return l10n.alertRuleNumberInvalid;
    if (_percent && (value < 0 || value > 100)) {
      return l10n.alertRulePercentInvalid;
    }
    return null;
  }

  String? _validateClear(AppLocalizations l10n, String? text) {
    if (_validateValue(l10n, text) case final invalid?) return invalid;
    final clear = _parse(text!)!;
    final raise = _parse(_raise.text);
    if (raise == null) return null;
    if (_above && clear > raise) return l10n.alertRuleClearAboveRaise;
    if (!_above && clear < raise) return l10n.alertRuleClearBelowRaise;
    return null;
  }

  String? _validateMinutes(AppLocalizations l10n, String? text) {
    final value = _parse(text ?? '');
    if (value == null || value < 0) return l10n.alertRuleMinutesInvalid;
    return null;
  }

  static Duration _minutes(String text) => Duration(
    milliseconds: (_parse(text)! * Duration.millisecondsPerMinute).round(),
  );

  /// A field's text changed; [build]'s [_canSave] reads the fields again.
  void _refreshValidity() => setState(() {});

  /// Whether the form's validators would all pass, run without showing
  /// their errors: [TextFormField.validator] still owns the messages the
  /// fields show after a failed save or a blur.
  bool _canSave(AppLocalizations l10n) =>
      _validateValue(l10n, _raise.text) == null &&
      _validateClear(l10n, _clear.text) == null &&
      _validateMinutes(l10n, _raiseFor.text) == null &&
      _validateMinutes(l10n, _clearFor.text) == null;

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final (scope, target) = _scope;
    Navigator.of(context).pop<AlertRuleEdit>((
      rule: alertRule(
        metric: _metric,
        scope: scope,
        op: _op,
        raise: ThresholdBound(
          value: _parse(_raise.text)!,
          duration: _minutes(_raiseFor.text),
        ),
        clear: ThresholdBound(
          value: _parse(_clear.text)!,
          duration: _minutes(_clearFor.text),
        ),
        severity: _severity,
        evalScope: widget.existing?.rule.evalScope ?? RuleEvalScope.client,
      ),
      target: target,
    ));
  }

  /// The scopes the editor offers: the rule's own, the server it was
  /// opened from and that server's group, and every server.
  List<(RuleScope, String?)> get _scopes {
    final server = widget.server;
    return {
      _ownScope,
      if (server != null) (RuleScope.server, server.id),
      if (server?.group case final group?) (RuleScope.group, group),
      (RuleScope.all, null),
    }.toList();
  }

  String _scopeText(AppLocalizations l10n, (RuleScope, String?) scope) =>
      switch (scope) {
        (RuleScope.server, final id) => l10n.alertRuleScopeServer(
          widget.serverName(id ?? ''),
        ),
        (RuleScope.group, final group) => l10n.alertRuleScopeGroup(group ?? ''),
        (RuleScope.all, _) => l10n.alertRuleScopeAll,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final materialL10n = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final metrics = {
      for (final metric in AlertMetric.values) metric.id,
      _ownMetric,
    };
    final suffix = _percent ? l10n.alertRulePercentSuffix : null;
    const gap = SizedBox(height: 12);
    return AlertDialog(
      title: Text(
        widget.existing == null ? l10n.alertRuleNew : l10n.alertRuleEdit,
      ),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.alertsCoverage,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              gap,
              DropdownButtonFormField<String>(
                initialValue: _metric,
                decoration: InputDecoration(
                  labelText: l10n.alertRuleMetricLabel,
                ),
                items: [
                  for (final metric in metrics)
                    DropdownMenuItem(
                      value: metric,
                      child: Text(alertMetricName(l10n, metric)),
                    ),
                ],
                onChanged: (metric) => setState(() => _metric = metric!),
              ),
              gap,
              DropdownButtonFormField<ThresholdOp>(
                initialValue: _op,
                decoration: InputDecoration(labelText: l10n.alertRuleOpLabel),
                items: [
                  for (final op in ThresholdOp.values)
                    DropdownMenuItem(
                      value: op,
                      child: Text(l10n.alertRuleOp(op.name)),
                    ),
                ],
                onChanged: (op) => setState(() => _op = op!),
              ),
              gap,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _raise,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.alertRuleRaiseValueLabel,
                        suffixText: suffix,
                      ),
                      validator: (text) => _validateValue(l10n, text),
                      onFieldSubmitted: (_) => _save(),
                    ),
                  ),
                  Expanded(
                    child: TextFormField(
                      controller: _raiseFor,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.alertRuleForLabel,
                      ),
                      validator: (text) => _validateMinutes(l10n, text),
                      onFieldSubmitted: (_) => _save(),
                    ),
                  ),
                ],
              ),
              gap,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _clear,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.alertRuleClearValueLabel,
                        suffixText: suffix,
                      ),
                      validator: (text) => _validateClear(l10n, text),
                      onFieldSubmitted: (_) => _save(),
                    ),
                  ),
                  Expanded(
                    child: TextFormField(
                      controller: _clearFor,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.alertRuleForLabel,
                      ),
                      validator: (text) => _validateMinutes(l10n, text),
                      onFieldSubmitted: (_) => _save(),
                    ),
                  ),
                ],
              ),
              gap,
              DropdownButtonFormField<AlertSeverity>(
                initialValue: _severity,
                decoration: InputDecoration(
                  labelText: l10n.alertRuleSeverityLabel,
                ),
                items: [
                  for (final severity in AlertSeverity.values.reversed)
                    DropdownMenuItem(
                      value: severity,
                      child: Text(l10n.alertSeverity(severity.name)),
                    ),
                ],
                onChanged: (severity) => setState(() => _severity = severity!),
              ),
              gap,
              DropdownButtonFormField<(RuleScope, String?)>(
                initialValue: _scope,
                decoration: InputDecoration(
                  labelText: l10n.alertRuleScopeLabel,
                ),
                items: [
                  for (final scope in _scopes)
                    DropdownMenuItem(
                      value: scope,
                      child: Text(_scopeText(l10n, scope)),
                    ),
                ],
                onChanged: (scope) => setState(() => _scope = scope!),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(materialL10n.cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _canSave(l10n) ? _save : null,
          child: Text(l10n.alertRuleSave),
        ),
      ],
    );
  }
}
