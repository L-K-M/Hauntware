/// Time helpers shared by the models: the Engine API mixes Unix seconds
/// and RFC3339Nano strings (03 §5.8). All values are UTC.
library;

/// Unix seconds to a UTC [DateTime], or null.
DateTime? dateTimeFromUnix(int? seconds) => seconds == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

/// RFC3339/RFC3339Nano text to a UTC [DateTime], or null. Nanoseconds
/// beyond microseconds are truncated (Dart's [DateTime] resolution); the
/// full value is preserved separately by the log timestamp type of 03
/// §5.6.
DateTime? dateTimeFromString(String? text) {
  if (text == null || text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  return parsed?.toUtc();
}
