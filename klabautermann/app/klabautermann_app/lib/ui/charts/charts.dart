/// The in-house charts (03 §10.7, D10): host-neutral painters that take
/// their words through [ChartStrings] and their colours from the theme, so
/// they can move to a shared package unchanged when a second app needs
/// them.
library;

export 'bars.dart'
    show BarSegment, PressureBar, PressureCell, StackedBar, pressureSummary;
export 'chart_style.dart';
export 'chart_values.dart' hide uncheckedChartScaleMax;
export 'core_heatmap.dart' show CoreHeatmap;
export 'gauge.dart' show Gauge;
export 'series_ring.dart';
export 'sparkline.dart' show Sparkline;
export 'time_series.dart' hide timeSeriesRuns;
export 'time_series_chart.dart' show TimeSeriesChart, chartGapText;
