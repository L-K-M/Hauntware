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
    trendRising: l10n.chartTrendRising,
    trendFalling: l10n.chartTrendFalling,
    trendSteady: l10n.chartTrendSteady,
    // The catalogue formats a fraction; chart percentages run 0 to 100.
    percent: (value) => l10n.chartPercent(value / 100),
  );
}
