/// The in-house charts (03 §10.7, D10): host-neutral painters that take
/// their words through [ChartStrings] and their colours from the theme, so
/// they can move to a shared package unchanged when a second app needs
/// them.
library;

export 'chart_style.dart';
export 'chart_values.dart' hide uncheckedChartScaleMax;
export 'series_ring.dart';
export 'sparkline.dart' show Sparkline;
