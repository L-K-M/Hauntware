import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

@immutable
sealed class ChatTarget {
  const ChatTarget();

  String get key;
  String get label;
  String get description;
  bool get hasTerminal;
}

final class GeneralChatTarget extends ChatTarget {
  const GeneralChatTarget();

  static const instance = GeneralChatTarget();

  @override
  String get key => 'general';
  @override
  String get label => 'General';
  @override
  String get description => 'No terminal selected';
  @override
  bool get hasTerminal => false;
}

/// A logical terminal identity. Labels are deliberately display-only.
@immutable
final class TerminalChatTarget extends ChatTarget {
  final String editSessionId;
  final String serverId;
  final String username;
  final String host;
  final int port;
  final bool isLocal;
  @override
  final String label;
  @override
  final String description;

  const TerminalChatTarget({
    required this.editSessionId,
    required this.serverId,
    required this.username,
    required this.host,
    required this.port,
    required this.isLocal,
    required this.label,
    required this.description,
  });

  @override
  String get key =>
      'terminal:${jsonEncode([editSessionId, serverId, username, host, port])}';
  @override
  bool get hasTerminal => true;

  @override
  bool operator ==(Object other) =>
      other is TerminalChatTarget && key == other.key;
  @override
  int get hashCode => key.hashCode;
}

@immutable
class ChatEntry {
  final bool fromUser;
  final String text;
  final List<String> staged;
  final List<String> searches;

  const ChatEntry({
    required this.fromUser,
    required this.text,
    this.staged = const [],
    this.searches = const [],
  });
}

class _TranscriptTurn {
  final List<ChatEntry> entries;
  final int bytes;
  const _TranscriptTurn(this.entries, this.bytes);
}

/// One bounded assistant conversation, independent of the sidebar widget.
class ChatSession extends ChangeNotifier {
  static const int maxTranscriptTurns = 50;
  static const int maxTranscriptContentBytes = 256 * 1024;
  static const int maxEntryContentBytes = 64 * 1024;

  final List<_TranscriptTurn> _turns = [];
  ChatEntry? _pendingUser;
  int _completedBytes = 0;
  ChatController? _controller;
  int? _controllerVersion;
  bool _sending = false;
  String? _error;
  String _draft = '';
  int _generation = 0;
  bool _disposed = false;

  List<ChatEntry> get entries => List.unmodifiable([
    for (final turn in _turns) ...turn.entries,
    if (_pendingUser case final pending?) pending,
  ]);
  bool get sending => _sending;
  String? get error => _error;
  String get draft => _draft;
  bool get isEmpty => _turns.isEmpty && _pendingUser == null;
  int get transcriptTurnCount => _turns.length + (_pendingUser == null ? 0 : 1);
  int get transcriptContentBytes =>
      _completedBytes + (_pendingUser == null ? 0 : _entryBytes(_pendingUser!));

  bool isCurrentTurn(int turn) => !_disposed && turn == _generation;

  ChatController? controllerFor(int configVersion) =>
      _controllerVersion == configVersion ? _controller : null;

  void adoptController(ChatController controller, int configVersion) {
    if (_disposed) {
      controller.close();
      throw StateError('The chat session is closed.');
    }
    if (!identical(_controller, controller)) _controller?.close();
    _controller = controller;
    _controllerVersion = configVersion;
  }

  void invalidateController() {
    final controller = _controller;
    _controller = null;
    _controllerVersion = null;
    controller?.close();
  }

  void updateDraft(String value) {
    if (_disposed) return;
    _draft = _clipUtf8(value, maxEntryContentBytes);
  }

  int addUserMessage(String text) {
    if (_disposed) throw StateError('The chat session is closed.');
    if (_sending) throw StateError('A chat turn is already running.');
    final entry = _boundedEntry(ChatEntry(fromUser: true, text: text));
    _pendingUser = entry;
    _pruneForPending(_entryBytes(entry));
    _error = null;
    _sending = true;
    notifyListeners();
    return _generation;
  }

  void addReply(int turn, ChatResult result) {
    if (!isCurrentTurn(turn) || _pendingUser == null) return;
    _completePending([
      _boundedEntry(
        ChatEntry(
          fromUser: false,
          text: result.reply,
          staged: result.stagedCommands,
          searches: result.searchQueries,
        ),
      ),
    ]);
    notifyListeners();
  }

  void failed(int turn, Object error) {
    if (!isCurrentTurn(turn)) return;
    if (_pendingUser != null) _completePending(const []);
    _error = _clipUtf8(error.toString(), maxEntryContentBytes);
    notifyListeners();
  }

  void finishSending(int turn) {
    if (!isCurrentTurn(turn) || !_sending) return;
    if (_pendingUser != null) _completePending(const []);
    _sending = false;
    notifyListeners();
  }

  void reset() {
    _generation++;
    _turns.clear();
    _pendingUser = null;
    _completedBytes = 0;
    _error = null;
    _draft = '';
    _sending = false;
    _controller?.reset();
    notifyListeners();
  }

  void _completePending(List<ChatEntry> suffix) {
    final pending = _pendingUser;
    if (pending == null) return;
    _pendingUser = null;
    final entries = List<ChatEntry>.unmodifiable([pending, ...suffix]);
    final bytes = entries.fold<int>(
      0,
      (sum, entry) => sum + _entryBytes(entry),
    );
    _turns.add(_TranscriptTurn(entries, bytes));
    _completedBytes += bytes;
    _pruneCompleted();
  }

  void _pruneForPending(int pendingBytes) {
    while (_turns.isNotEmpty &&
        (_turns.length + 1 > maxTranscriptTurns ||
            _completedBytes + pendingBytes > maxTranscriptContentBytes)) {
      final removed = _turns.removeAt(0);
      _completedBytes -= removed.bytes;
    }
  }

  void _pruneCompleted() {
    while (_turns.length > maxTranscriptTurns ||
        _completedBytes > maxTranscriptContentBytes) {
      final removed = _turns.removeAt(0);
      _completedBytes -= removed.bytes;
    }
  }

  static ChatEntry _boundedEntry(ChatEntry entry) {
    var remaining = maxEntryContentBytes;
    String take(String value) {
      final clipped = _clipUtf8(value, remaining);
      remaining -= utf8.encode(clipped).length;
      return clipped;
    }

    // Preserve staged commands first: they are the durable record of what was
    // placed in a prompt and drive the danger warning. Reply prose and search
    // audit text may be clipped rather than silently dropping that record.
    final staged = <String>[];
    for (final command in entry.staged) {
      if (remaining == 0) break;
      staged.add(take(command));
    }
    final text = take(entry.text);
    final searches = <String>[];
    for (final search in entry.searches) {
      if (remaining == 0) break;
      searches.add(take(search));
    }
    return ChatEntry(
      fromUser: entry.fromUser,
      text: text,
      searches: List.unmodifiable(searches),
      staged: List.unmodifiable(staged),
    );
  }

  static int _entryBytes(ChatEntry entry) =>
      utf8.encode(entry.text).length +
      entry.searches.fold<int>(
        0,
        (sum, value) => sum + utf8.encode(value).length,
      ) +
      entry.staged.fold<int>(
        0,
        (sum, value) => sum + utf8.encode(value).length,
      );

  static String _clipUtf8(String value, int maxBytes) {
    if (maxBytes <= 0) return '';
    if (utf8.encode(value).length <= maxBytes) return value;
    const ellipsis = '…';
    final ellipsisBytes = utf8.encode(ellipsis).length;
    if (maxBytes < ellipsisBytes) return '';
    final buffer = StringBuffer();
    var used = 0;
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      final bytes = utf8.encode(character).length;
      if (used + bytes + ellipsisBytes > maxBytes) break;
      buffer.write(character);
      used += bytes;
    }
    return '$buffer$ellipsis';
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    invalidateController();
    super.dispose();
  }
}

/// General plus a bounded conversation for each currently open terminal.
class ChatConversationStore extends ChangeNotifier {
  final Map<String, ChatSession> _sessions = {
    GeneralChatTarget.instance.key: ChatSession(),
  };
  Map<String, ChatTarget> _targets = {
    GeneralChatTarget.instance.key: GeneralChatTarget.instance,
  };
  String _selectedKey = GeneralChatTarget.instance.key;
  int _selectionEpoch = 0;
  bool _selectionInitialized = false;
  bool _disposed = false;
  ChatSession? _listenedSession;

  ChatConversationStore() {
    _listenToSelectedSession();
  }

  List<ChatTarget> get targets => List.unmodifiable(_targets.values);
  ChatTarget get selectedTarget => _targets[_selectedKey]!;
  ChatSession get selectedSession => conversationFor(selectedTarget);
  int get selectionEpoch => _selectionEpoch;

  ChatSession conversationFor(ChatTarget target) {
    if (_disposed) throw StateError('The chat conversation store is closed.');
    if (!_targets.containsKey(target.key)) {
      throw StateError('The chat target is no longer open.');
    }
    return _sessions.putIfAbsent(target.key, ChatSession.new);
  }

  void select(String key) {
    if (_disposed || !_targets.containsKey(key)) return;
    if (key == _selectedKey) {
      initializeSelection();
      return;
    }
    _selectionInitialized = true;
    _selectedKey = key;
    _selectionEpoch++;
    _sessions.putIfAbsent(key, ChatSession.new);
    _listenToSelectedSession();
    notifyListeners();
  }

  /// Make General an explicit choice when the assistant is first opened with
  /// no terminal. Later tabs must not silently pull that conversation over.
  void initializeSelection() {
    if (_disposed || _selectionInitialized) return;
    _selectionInitialized = true;
  }

  void reconcile(
    Iterable<TerminalChatTarget> terminals, {
    TerminalChatTarget? initiallyActive,
  }) {
    if (_disposed) return;
    final next = <String, ChatTarget>{
      GeneralChatTarget.instance.key: GeneralChatTarget.instance,
      for (final target in terminals) target.key: target,
    };
    var changed = !_sameTargets(_targets, next);
    for (final key in _sessions.keys.toList()) {
      if (!next.containsKey(key)) {
        final removed = _sessions.remove(key);
        if (identical(removed, _listenedSession)) {
          _listenedSession?.removeListener(_selectedSessionChanged);
          _listenedSession = null;
        }
        removed?.dispose();
        changed = true;
      }
    }
    _targets = next;

    if (!_selectionInitialized) {
      final preferred = initiallyActive?.key;
      final provisional = preferred != null && next.containsKey(preferred)
          ? preferred
          : GeneralChatTarget.instance.key;
      if (_selectedKey != provisional) {
        _selectedKey = provisional;
        _selectionEpoch++;
        changed = true;
      }
    } else if (!next.containsKey(_selectedKey)) {
      _selectedKey = GeneralChatTarget.instance.key;
      _selectionEpoch++;
      changed = true;
    }
    _sessions.putIfAbsent(_selectedKey, ChatSession.new);
    _listenToSelectedSession();
    if (changed) notifyListeners();
  }

  void invalidateControllers() {
    for (final session in _sessions.values) {
      session.invalidateController();
    }
  }

  static bool _sameTargets(
    Map<String, ChatTarget> oldTargets,
    Map<String, ChatTarget> newTargets,
  ) {
    if (!listEquals(oldTargets.keys.toList(), newTargets.keys.toList())) {
      return false;
    }
    for (final key in oldTargets.keys) {
      final old = oldTargets[key]!;
      final next = newTargets[key]!;
      if (old.label != next.label || old.description != next.description) {
        return false;
      }
    }
    return true;
  }

  void _listenToSelectedSession() {
    final selected = _sessions[_selectedKey];
    if (identical(selected, _listenedSession)) return;
    _listenedSession?.removeListener(_selectedSessionChanged);
    _listenedSession = selected;
    _listenedSession?.addListener(_selectedSessionChanged);
  }

  void _selectedSessionChanged() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listenedSession?.removeListener(_selectedSessionChanged);
    _listenedSession = null;
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    _targets = const {};
    super.dispose();
  }
}
