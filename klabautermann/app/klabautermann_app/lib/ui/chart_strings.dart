import '../l10n/app_localizations.dart';
import 'charts/charts.dart' show ChartStrings;

/// The charts' string bag from Klabautermann's ARB (03 §10.10's adapter-file
/// convention, D10: the charts keep their words host-supplied).
ChartStrings klabautermannChartStrings(AppLocalizations l10n) {
  return ChartStrings(
    seriesSummary: l10n.chartSeriesSummary,
    seriesEmpty: l10n.chartSeriesEmpty,
    seriesUnknown: l10n.chartSeriesUnknown,
    unknownValue: l10n.chartUnknownValue,
    gapAppClosed: l10n.chartGapAppClosed,
    gapBackground: l10n.chartGapBackground,
    gapDisconnected: l10n.chartGapDisconnected,
    gapReadingFailed: l10n.chartGapReadingFailed,
    gapSummary: l10n.chartGapSummary,
    gapOngoing: l10n.chartGapOngoing,
    time: l10n.chartTime,
    timeWithSeconds: l10n.chartTimeWithSeconds,
    trendRising: l10n.chartTrendRising,
    trendFalling: l10n.chartTrendFalling,
    trendSteady: l10n.chartTrendSteady,
    // The catalogue formats a fraction; chart percentages run 0 to 100.
    percent: (value) => l10n.chartPercent(value / 100),
    barSummary: l10n.chartBarSummary,
    barPart: l10n.chartBarPart,
    listSeparator: l10n.chartListSeparator,
    withSeverity: l10n.chartWithSeverity,
    severityCareful: l10n.chartSeverityCareful,
    severityWarning: l10n.chartSeverityWarning,
    severityCritical: l10n.chartSeverityCritical,
    stale: l10n.chartStale,
  );
}
