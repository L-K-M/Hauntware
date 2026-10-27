import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// Séance's snippets the account carries (03 §7.21, AUT-01), as the
/// engine reports them. Read-only: Séance owns them, so Klabautermann
/// runs them and never edits one.
final class SnippetsController extends ChangeNotifier {
  SnippetsController(EngineClient engine) {
    _events = engine.events.listen(_onEngineEvent);
  }

  late final StreamSubscription<EngineEvent> _events;
  List<Snippet> _snippets = const [];

  /// Every live snippet, by title.
  List<Snippet> get snippets => _snippets;

  void _onEngineEvent(EngineEvent event) {
    if (event case SnippetsChanged(:final snippets)) {
      _snippets = List.unmodifiable(snippets);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    super.dispose();
  }
}
