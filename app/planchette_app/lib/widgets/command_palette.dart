import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One command the palette can run: a menu item, named with its path.
final class PaletteCommand {
  const PaletteCommand({
    required this.id,
    required this.label,
    required this.path,
    required this.run,
    this.description = '',
    this.keywords = const [],
    this.shortcut,
    this.enabled = true,
  });

  /// The menu's stable identifier for the command, so a label that
  /// changes still resolves.
  final String id;
  final String label;

  /// Where the command lives in the menus, shown on the row so a palette
  /// search teaches where the item is: "Text > Lines".
  final String path;

  /// What the command does, on the row's second line.
  final String description;

  /// More words the command matches by — "dedupe" finds Remove
  /// Duplicate Lines.
  final List<String> keywords;
  final VoidCallback run;
  final SingleActivator? shortcut;

  /// Whether the command applies right now; a greyed row stays listed so
  /// the palette still answers "where is that command".
  final bool enabled;
}

/// Shows the palette over [context]'s navigator and runs the command the
/// user picks once the palette has closed, so a command that moves focus or
/// opens a dialog of its own is not fighting the palette for either.
Future<void> showCommandPalette(
  BuildContext context,
  List<PaletteCommand> commands,
) async {
  final chosen = await showDialog<PaletteCommand>(
    context: context,
    barrierColor: Colors.black12,
    builder: (context) => CommandPalette(commands: commands),
  );
  chosen?.run();
}

/// A subsequence match of [query] in [candidate], ignoring case and spaces
/// in the query, or null when some character is missing. Of all the ways
/// the query fits, the best-scoring one wins: characters at word starts and
/// in consecutive runs score extra, and each gap costs a little, so "fn"
/// finds Find Next by its initials while "fin" still prefers Find.
({int score, List<int> positions})? fuzzyMatch(String query, String candidate) {
  final needle = query.toLowerCase().replaceAll(' ', '');
  final haystack = candidate.toLowerCase();
  if (needle.isEmpty) return (score: 0, positions: const []);
  final length = haystack.length;
  // best[i]: the best score with the current query character at i, and
  // links[q][i] the position its predecessor took. Labels are short, so the
  // quadratic step costs nothing noticeable.
  var best = List<int?>.filled(length, null);
  for (var i = 0; i < length; i++) {
    if (haystack[i] == needle[0]) best[i] = _gain(haystack, i);
  }
  final links = <List<int>>[List.filled(length, -1)];
  for (var q = 1; q < needle.length; q++) {
    final next = List<int?>.filled(length, null);
    final link = List.filled(length, -1);
    for (var i = q; i < length; i++) {
      if (haystack[i] != needle[q]) continue;
      for (var j = 0; j < i; j++) {
        final previous = best[j];
        if (previous == null) continue;
        final score = previous + _gain(haystack, i, previous: j);
        if (next[i] == null || score > next[i]!) {
          next[i] = score;
          link[i] = j;
        }
      }
    }
    best = next;
    links.add(link);
  }

  var end = -1;
  for (var i = 0; i < length; i++) {
    if (best[i] != null && (end < 0 || best[i]! > best[end]!)) end = i;
  }
  if (end < 0) return null;
  final positions = List.filled(needle.length, 0);
  for (var q = needle.length - 1, at = end; q >= 0; at = links[q][at], q--) {
    positions[q] = at;
  }
  return (score: best[end]!, positions: positions);
}

const _wordStartBonus = 8;

const _consecutiveBonus = 6;
const _maximumGapPenalty = 3;

int _gain(String text, int index, {int? previous}) {
  var gain = 1;
  if (_isWordStart(text, index)) gain += _wordStartBonus;
  if (previous != null) {
    final gap = index - previous - 1;
    gain += gap == 0 ? _consecutiveBonus : -math.min(gap, _maximumGapPenalty);
  }
  return gain;
}

bool _isWordStart(String text, int index) =>
    _isWordCharacter(text.codeUnitAt(index)) &&
    (index == 0 || !_isWordCharacter(text.codeUnitAt(index - 1)));

bool _isWordCharacter(int unit) =>
    (unit >= 0x30 && unit <= 0x39) || (unit >= 0x61 && unit <= 0x7a);

/// How a shortcut is written on this platform: symbols on Apple platforms,
/// `Ctrl+Shift+S` elsewhere.
String shortcutLabel(SingleActivator activator, {required bool apple}) {
  final key = switch (activator.trigger) {
    LogicalKeyboardKey.arrowUp => apple ? '↑' : 'Up',
    LogicalKeyboardKey.arrowDown => apple ? '↓' : 'Down',
    LogicalKeyboardKey.arrowLeft => apple ? '←' : 'Left',
    LogicalKeyboardKey.arrowRight => apple ? '→' : 'Right',
    LogicalKeyboardKey.tab => apple ? '⇥' : 'Tab',
    final other => other.keyLabel,
  };
  if (apple) {
    return [
      if (activator.control) '⌃',
      if (activator.alt) '⌥',
      if (activator.shift) '⇧',
      if (activator.meta) '⌘',
      key,
    ].join();
  }
  return [
    if (activator.control) 'Ctrl',
    if (activator.alt) 'Alt',
    if (activator.shift) 'Shift',
    if (activator.meta) 'Meta',
    key,
  ].join('+');
}

/// The palette itself: a filter field over the commands. Up and Down move
/// the highlight, Enter or a click runs it, Escape closes.
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.commands});

  final List<PaletteCommand> commands;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

/// A listed command plus how it matched: label characters to bold, and
/// the keyword it matched when the label did not.
typedef _Row = ({PaletteCommand command, List<int> positions, String? keyword});

class _CommandPaletteState extends State<CommandPalette> {
  static const _rowHeight = 48.0;
  static const _visibleRows = 10;

  final _query = TextEditingController();
  final _scroll = ScrollController();
  List<_Row> _rows = const [];
  String? _filtered;
  int _highlighted = 0;

  @override
  void initState() {
    super.initState();
    _filter();
    _query.addListener(() {
      // The field also notifies for caret moves, which must not re-sort.
      if (_query.text != _filtered) setState(_filter);
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _filter() {
    _filtered = _query.text;
    // Tiers: a label match, then a keyword match, then a path match.
    // "dedupe" matches Remove Duplicate Lines by keyword; typing "text"
    // lists the menu by path.
    final scored = <({_Row row, int tier, int score, int order})>[];
    for (var i = 0; i < widget.commands.length; i++) {
      final command = widget.commands[i];
      final match = fuzzyMatch(_query.text, command.label);
      if (match != null) {
        scored.add((
          row: (command: command, positions: match.positions, keyword: null),
          tier: 0,
          score: match.score,
          order: i,
        ));
        continue;
      }
      var keywordMatched = false;
      for (final keyword in command.keywords) {
        if (fuzzyMatch(_query.text, keyword) != null) {
          scored.add((
            row: (command: command, positions: const [], keyword: keyword),
            tier: 1,
            score: 0,
            order: i,
          ));
          keywordMatched = true;
          break;
        }
      }
      if (keywordMatched) continue;
      if (fuzzyMatch(_query.text, command.path) != null) {
        // Typing a menu's name lists that menu, after every label match and
        // with nothing highlighted, since the name is not in the label. A
        // flag, not a low score: a scattered label match can score below
        // zero too.
        scored.add((
          row: (command: command, positions: const [], keyword: null),
          tier: 2,
          score: 0,
          order: i,
        ));
      }
    }
    // A shorter label is the closer match on a tie; then menu order, so an
    // empty query lists the menus as they are.
    scored.sort((a, b) {
      if (a.tier != b.tier) return a.tier.compareTo(b.tier);
      if (a.score != b.score) return b.score.compareTo(a.score);
      if (_query.text.isNotEmpty && a.tier == 0) {
        final shorter = a.row.command.label.length.compareTo(
          b.row.command.label.length,
        );
        if (shorter != 0) return shorter;
      }
      return a.order.compareTo(b.order);
    });
    _rows = [for (final entry in scored) entry.row];
    _highlighted = 0;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _move(int delta) {
    if (_rows.isEmpty) return;
    setState(() {
      _highlighted = (_highlighted + delta) % _rows.length;
    });
    final top = _highlighted * _rowHeight;
    final position = _scroll.position;
    if (top < position.pixels) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight >
        position.pixels + position.viewportDimension) {
      _scroll.jumpTo(top + _rowHeight - position.viewportDimension);
    }
  }

  void _run(int index) {
    if (index < 0 || index >= _rows.length) return;
    final command = _rows[index].command;
    // A greyed row answers "where is it" but cannot run right now.
    if (!command.enabled) return;
    Navigator.pop(context, command);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(16, 64, 16, 16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _move(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _move(-1),
                },
                child: TextField(
                  key: const ValueKey('planchette.palette.query'),
                  controller: _query,
                  autofocus: true,
                  onSubmitted: (_) => _run(_highlighted),
                  decoration: const InputDecoration(
                    hintText: 'Type a command',
                    prefixIcon: Icon(Icons.search, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            if (_rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No matching commands',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: _rowHeight * _visibleRows,
                ),
                child: ListView.builder(
                  controller: _scroll,
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemExtent: _rowHeight,
                  itemCount: _rows.length,
                  itemBuilder: (context, index) =>
                      _row(context, index, _rows[index]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int index, _Row row) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final apple = switch (theme.platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };
    final highlighted = index == _highlighted;
    final command = row.command;
    final dim = TextStyle(
      color: command.enabled
          ? scheme.onSurfaceVariant
          : scheme.onSurfaceVariant.withValues(alpha: 0.5),
      fontSize: 12,
    );
    // Line two says what the command does, and when a keyword rather than
    // the label matched, which word found it.
    final detail = switch ((row.keyword, command.description)) {
      (final keyword?, '') => 'matches "$keyword"',
      (final keyword?, final description) =>
        'matches "$keyword" — $description',
      (null, final description) => description,
    };
    final label = command.label;
    final matched = row.positions.toSet();
    return Material(
      color: highlighted ? scheme.secondaryContainer : Colors.transparent,
      child: Semantics(
        // The row stays tappable so a tap cannot fall through to the
        // barrier, but assistive tech still hears it is unavailable.
        enabled: command.enabled,
        child: InkWell(
          // Always tappable; _run declines a disabled command.
          onTap: () => _run(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            for (var i = 0; i < label.length; i++)
                              TextSpan(
                                text: label[i],
                                style: matched.contains(i)
                                    ? const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      )
                                    : null,
                              ),
                          ],
                        ),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: !command.enabled
                              ? scheme.onSurface.withValues(alpha: 0.4)
                              : highlighted
                              ? scheme.onSecondaryContainer
                              : scheme.onSurface,
                        ),
                      ),
                    ),
                    Text(command.path, style: dim),
                    if (command.shortcut case final shortcut?) ...[
                      const SizedBox(width: 12),
                      Text(shortcutLabel(shortcut, apple: apple), style: dim),
                    ],
                  ],
                ),
                if (detail.isNotEmpty)
                  Text(detail, style: dim, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
