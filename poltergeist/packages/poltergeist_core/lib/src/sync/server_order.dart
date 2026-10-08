import 'package:seance_core/seance_core.dart';

/// The order servers are listed and stored in: label without regard to
/// case, then id, so equal labels still sort the same way every time.
int compareServersByLabel(ServerConfig a, ServerConfig b) {
  final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
  return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
}
