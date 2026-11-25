import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../sortable_table.dart';

/// The order, search and watch state the Docker list sub-tabs share
/// (UIB-6, ARC-04): which column and direction the rows take, the search
/// text and its focus, and the server's watch this panel holds.
///
/// The order and search outlive sub-tab switches, because the tab keeps
/// a sub-tab built once opened. [sync] holds the watch while [visible],
/// lets it go when the panel hides or the server changes, and clears the
/// search on a server switch; [dispose] releases and closes the
/// controllers.
final class DockerListState {
  DockerListState({
    required TableSort initialSort,
    required this._watch,
    required this._unwatch,
    this._onRelease,
    this._onServerChanged,
    this._onWatched,
  }) : sort = initialSort;

  TableSort sort;

  final TextEditingController search = TextEditingController();

  /// The filter field, which `/` in the table focuses (PLT-06).
  final FocusNode searchFocus = FocusNode();

  String? _held;
  String? _serverId;

  final void Function(String serverId) _watch;
  final void Function(String serverId) _unwatch;
  final void Function()? _onRelease;
  final void Function()? _onServerChanged;
  final void Function()? _onWatched;

  /// Keeps the watch while [visible], over [serverId]. A server switch
  /// releases the old watch and clears the search first.
  void sync({required bool visible, required String serverId}) {
    if (serverId != _serverId) {
      release();
      _onServerChanged?.call();
      search.clear();
      _serverId = serverId;
    }
    final wanted = visible ? serverId : null;
    if (_held == wanted) return;
    release();
    if (wanted == null) return;

    _watch(wanted);
    _held = wanted;
    _onWatched?.call();
  }

  /// The server whose watch is held, if any; a caller that reports what
  /// is on screen needs to know whether a watch can take it.
  String? get held => _held;

  /// Lets the held watch go, if any.
  void release() {
    _onRelease?.call();
    final held = _held;
    if (held == null) return;

    _held = null;
    _unwatch(held);
  }

  void dispose() {
    release();
    search.dispose();
    searchFocus.dispose();
  }
}

/// The search field of a Docker list sub-tab: a hint, and a clear button
/// once it holds text. `/` in the table focuses it (PLT-06).
class DockerListSearchField extends StatelessWidget {
  const DockerListSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.clearTooltip,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final String clearTooltip;

  /// Rebuilds after typing or clearing.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 420),
    child: TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: (_) => onChanged(),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: hint,
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: clearTooltip,
                icon: const Icon(Icons.clear),
                onPressed: () {
                  controller.clear();
                  onChanged();
                },
              ),
      ),
    ),
  );
}

/// A Docker list sub-tab's search field and filter chips: [filters] with
/// [label]s, the selected one filled, the rest disabled while [enabled]
/// is false.
class DockerListFilterRow<F extends Enum> extends StatelessWidget {
  const DockerListFilterRow({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.clearTooltip,
    required this.filters,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onChanged,
    required this.onSelected,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final String clearTooltip;
  final List<F> filters;
  final String Function(AppLocalizations l10n, F filter) label;
  final F selected;
  final bool enabled;
  final VoidCallback onChanged;
  final ValueChanged<F> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DockerListSearchField(
          controller: controller,
          focusNode: focusNode,
          hint: hint,
          clearTooltip: clearTooltip,
          onChanged: onChanged,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final filter in filters)
              ChoiceChip(
                label: Text(label(l10n, filter)),
                selected: selected == filter,
                onSelected: enabled ? (_) => onSelected(filter) : null,
              ),
          ],
        ),
      ],
    );
  }
}
