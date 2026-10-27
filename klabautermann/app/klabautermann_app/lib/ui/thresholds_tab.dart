import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../controllers/threshold_controller.dart';
import '../l10n/app_localizations.dart';
import 'charts/charts.dart' show ChartThresholds;
import 'threshold_scope.dart';

/// The Alerts tab's usage bands (OV-11): each metric's careful, warning
/// and critical levels, which the fleet rows, the Overview's gauges and
/// the health card judge by, each edited in a dialog that refuses levels
/// out of order.
class ThresholdsTab extends StatelessWidget {
  const ThresholdsTab({super.key, required this.thresholds});

  final ThresholdSettings thresholds;

  static String metricName(AppLocalizations l10n, ThresholdMetric metric) =>
      l10n.settingsThresholdMetric(metric.name);

  Future<void> _edit(BuildContext context, ThresholdMetric metric) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    final levels = await showDialog<ChartThresholds>(
      context: context,
      builder: (_) => _ThresholdDialog(
        title: metricName(l10n, metric),
        levels: thresholds.value[metric] ?? kDefaultThresholds,
      ),
    );
    if (levels == null) return;
    try {
      await thresholds.setThresholds(metric, levels);
    } on ThresholdsNotSavedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsThresholdsNotSaved);
      }
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsThresholdsNotChanged);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String percent(double value) => l10n.chartPercent(value / 100);
    return ListenableBuilder(
      listenable: thresholds,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.settingsThresholdsTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 4),
          Text(l10n.settingsThresholdsDetail),
          const SizedBox(height: 8),
          for (final metric in ThresholdMetric.values)
            if (thresholds.value[metric] ?? kDefaultThresholds
                case final levels)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(metricName(l10n, metric)),
                subtitle: Text(
                  l10n.settingsThresholdLevels(
                    percent(levels.careful!),
                    percent(levels.warning),
                    percent(levels.critical),
                  ),
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => unawaited(_edit(context, metric)),
              ),
        ],
      ),
    );
  }
}

/// Edits one metric's three levels: whole percents from 1 to 100, each
/// above the one before; Default fills in [kDefaultThresholds].
class _ThresholdDialog extends StatefulWidget {
  const _ThresholdDialog({required this.title, required this.levels});

  final String title;
  final ChartThresholds levels;

  @override
  State<_ThresholdDialog> createState() => _ThresholdDialogState();
}

class _ThresholdDialogState extends State<_ThresholdDialog> {
  late final _careful = _field(widget.levels.careful!);
  late final _warning = _field(widget.levels.warning);
  late final _critical = _field(widget.levels.critical);
  bool _invalid = false;

  static TextEditingController _field(double value) =>
      TextEditingController(text: value.round().toString());

  @override
  void dispose() {
    _careful.dispose();
    _warning.dispose();
    _critical.dispose();
    super.dispose();
  }

  /// The levels typed, or null when one is missing or they are invalid.
  ChartThresholds? get _levels {
    final [careful, warning, critical] = [
      for (final field in [_careful, _warning, _critical])
        double.tryParse(field.text),
    ];
    if (careful == null || warning == null || critical == null) return null;
    return thresholdsOf(careful, warning, critical);
  }

  void _save() {
    final levels = _levels;
    if (levels == null) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(levels);
  }

  void _restoreDefault() {
    setState(() {
      _careful.text = kDefaultThresholds.careful!.round().toString();
      _warning.text = kDefaultThresholds.warning.round().toString();
      _critical.text = kDefaultThresholds.critical.round().toString();
      _invalid = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    Widget field(TextEditingController controller, String label) => TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        suffixText: l10n.settingsThresholdPercentSuffix,
      ),
      onChanged: (_) {
        if (_invalid) setState(() => _invalid = false);
      },
      onSubmitted: (_) => _save(),
    );
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          field(_careful, l10n.settingsThresholdCareful),
          field(_warning, l10n.settingsThresholdWarning),
          field(_critical, l10n.settingsThresholdCritical),
          if (_invalid)
            Text(
              l10n.settingsThresholdsInvalid,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _restoreDefault,
          child: Text(l10n.settingsThresholdDefault),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.settingsThresholdCancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.settingsThresholdSave)),
      ],
    );
  }
}
