import 'package:flutter/foundation.dart';

/// Session-only find queries, newest first.
///
/// Kept in memory and never written to disk: a query can hold a secret
/// (a token, a name), and the plan keeps search history session-only like
/// text-tool text options for the same reason. Bounded so a long session
/// cannot grow it without limit.
final class SearchHistory extends ChangeNotifier {
  SearchHistory({this.keep = 30});

  /// How many queries are remembered.
  final int keep;

  final List<String> _queries = [];

  /// Newest first, for a history popup or keyboard recall.
  List<String> get queries => List.unmodifiable(_queries);

  /// Records [query]: empty queries are ignored, a repeat of the newest
  /// changes nothing, and an older repeat moves to the front.
  void push(String query) {
    if (query.isEmpty) return;
    final index = _queries.indexOf(query);
    if (index == 0) return;
    if (index > 0) _queries.removeAt(index);
    _queries.insert(0, query);
    while (_queries.length > keep) {
      _queries.removeLast();
    }
    notifyListeners();
  }

  void clear() {
    if (_queries.isEmpty) return;
    _queries.clear();
    notifyListeners();
  }
}
