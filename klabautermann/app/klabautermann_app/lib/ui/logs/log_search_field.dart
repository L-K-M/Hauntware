import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'log_query.dart';
import 'log_search.dart';

/// How long the search waits for typing to pause: a new query searches
/// every line held ([LogSearch]).
const Duration _searchDebounce = Duration(milliseconds: 200);

/// LOG-05's search field over the lines held, with case matching, LOG-06's
/// regular expressions and stepping; Enter steps to the next match. With
/// [onSearchServer], a button hands the search to the server as a
/// journalctl pattern ([serverLogPattern]).
class LogSearchField extends StatefulWidget {
  const LogSearchField({
    super.key,
    required this.search,
    this.onSearchServer,
    this.compact = false,
  });

  final LogSearch search;
  final ValueChanged<String>? onSearchServer;

  /// Whether the field sits on a phone-width row of its own.
  final bool compact;

  @override
  State<LogSearchField> createState() => _LogSearchFieldState();
}

class _LogSearchFieldState extends State<LogSearchField> {
  late final _text = TextEditingController(text: widget.search.query);
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      // The text too: the server button follows what is typed, which the
      // debounced search lags behind by up to [_searchDebounce].
      listenable: Listenable.merge([widget.search, _text]),
      builder: (context, _) {
        final search = widget.search;
        final steppable = search.total > 0;
        final onSearchServer = widget.onSearchServer;
        final field = TextField(
          controller: _text,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          onChanged: (query) {
            _debounce?.cancel();
            _debounce = Timer(_searchDebounce, () => search.setQuery(query));
          },
          // Enter steps on and keeps the focus for the next step.
          onEditingComplete: () {},
          onSubmitted: (query) {
            _debounce?.cancel();
            search
              ..setQuery(query)
              ..next();
          },
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.search),
            // A label, not a hint, so the field keeps its name for
            // screen readers once it holds text.
            labelText: l10n.logsPanelSearchLabel,
            // The journal's PCRE2 reads some patterns Dart's engine does
            // not (inline flags), so the server may still take one.
            errorText: switch (search) {
              LogSearch(invalidPattern: true) =>
                onSearchServer == null
                    ? l10n.logsPanelSearchInvalid
                    : l10n.logsPanelSearchInvalidLocal,
              LogSearch(tooCostly: true) => l10n.logsPanelSearchTooCostly,
              _ => null,
            },
            suffixText:
                search.query.isEmpty ||
                    search.invalidPattern ||
                    search.tooCostly
                ? null
                : switch (search.currentNumber) {
                    // A pattern is still reading the rows held: the
                    // count so far would read as the whole.
                    _ when search.searching => l10n.logsPanelSearchSearching,
                    final number? => l10n.logsPanelSearchPosition(
                      number,
                      search.total,
                    ),
                    null => l10n.logsPanelSearchMatches(search.total),
                  },
          ),
        );
        // Outlined when off and filled when on, so the state shows by
        // more than colour (03 §10.10).
        final toggles = [
          IconButton.outlined(
            isSelected: search.caseSensitive,
            icon: const Icon(Icons.text_fields),
            tooltip: l10n.logsPanelSearchCase,
            onPressed: () => search.setCaseSensitive(!search.caseSensitive),
          ),
          IconButton.outlined(
            isSelected: search.regex,
            icon: const Icon(Icons.data_object),
            tooltip: l10n.logsPanelSearchRegex,
            onPressed: () => search.setRegex(!search.regex),
          ),
          if (onSearchServer != null)
            IconButton(
              icon: const Icon(Icons.travel_explore),
              tooltip: l10n.logsPanelSearchServer,
              onPressed: _text.text.isEmpty
                  ? null
                  : () {
                      // Take the typed text now, not the debounced one.
                      _debounce?.cancel();
                      search.setQuery(_text.text);
                      onSearchServer(
                        serverLogPattern(
                          _text.text,
                          regex: search.regex,
                          caseSensitive: search.caseSensitive,
                        ),
                      );
                    },
            ),
        ];
        final steps = [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up),
            tooltip: l10n.logsPanelSearchPrevious,
            onPressed: steppable ? search.previous : null,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            tooltip: l10n.logsPanelSearchNext,
            onPressed: steppable ? search.next : null,
          ),
        ];
        // Five buttons beside the field would leave it 56 px wide at
        // 320 px: on a phone the toggles take their own row.
        if (!widget.compact) {
          return Row(
            children: [
              Expanded(child: field),
              ...toggles,
              ...steps,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: field),
                ...steps,
              ],
            ),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: toggles),
          ],
        );
      },
    );
  }
}
