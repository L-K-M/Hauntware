import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../l10n/app_localizations.dart';
import 'fleet_row_state.dart';

const double _dialogMaxWidth = 560;

/// The least height at which the list keeps its actions in view below
/// the rows rather than scrolling them with the rows.
const double _pinnedActionsMinHeight = 400;

/// Atop the fleet rows (the desktop rail, the phone's home), scrolling
/// with them ([FleetServerList.header]): how many synced servers wait for
/// their endpoints to be confirmed (03 §4.3 step 3, §4.7), with the way
/// to the confirmation list. Nothing while none does, so it appears after
/// a sign-in or a sync that brings them.
class EndpointsPendingNotice extends StatelessWidget {
  const EndpointsPendingNotice({super.key, required this.fleet});

  final FleetController fleet;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: fleet,
    builder: (context, _) {
      final count = fleet.pendingEndpoints.length;
      if (count == 0) return const SizedBox.shrink();

      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      // The action sits under the text rather than beside it, so the
      // narrow desktop rail keeps both readable.
      return Material(
        color: colors.secondaryContainer,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                spacing: 12,
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    color: colors.onSecondaryContainer,
                  ),
                  Expanded(
                    // A state change, which screen readers hear
                    // (A11Y-15).
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.endpointsPendingNotice(count),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => showEndpointConfirmation(context, fleet),
                  child: Text(l10n.endpointsReview),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Opens the batch endpoint confirmation (03 §4.3 step 3) over [context].
Future<void> showEndpointConfirmation(
  BuildContext context,
  FleetController fleet,
) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _dialogMaxWidth),
      child: EndpointConfirmationDialog(fleet: fleet),
    ),
  ),
);

/// The confirmation list (03 §4.3 step 3, SAF-09): each synced server
/// waiting for confirmation with its host, port, user and jump route, a
/// search, a toggle per row, and "confirm all shown" for the rows the
/// search leaves. It follows the fleet, so a server confirmed or gone
/// meanwhile leaves the list.
class EndpointConfirmationDialog extends StatefulWidget {
  const EndpointConfirmationDialog({super.key, required this.fleet});

  final FleetController fleet;

  @override
  State<EndpointConfirmationDialog> createState() =>
      _EndpointConfirmationDialogState();
}

class _EndpointConfirmationDialogState
    extends State<EndpointConfirmationDialog> {
  final _search = TextEditingController();
  final Set<String> _selected = {};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _confirm(List<String> serverIds) async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.fleet.confirmEndpoints(serverIds);
    if (!mounted) return;

    switch (result) {
      case EndpointConfirmResult.confirmed:
        Navigator.of(context).pop();
        showTopToast(
          overlay,
          message: l10n.endpointsConfirmed(serverIds.length),
        );
      case EndpointConfirmResult.stillPending:
        setState(() {
          _selected.removeAll(serverIds);
          _busy = false;
          _error = l10n.endpointsStillPending;
        });
      // The toggles stay, so trying again is one press.
      case EndpointConfirmResult.failed:
        setState(() {
          _busy = false;
          _error = l10n.endpointsFailed;
        });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.fleet, _search]),
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final material = MaterialLocalizations.of(context);
      final theme = Theme.of(context);
      final pending = widget.fleet.pendingEndpoints;
      final shown = [
        for (final entry in pending)
          if (fleetServerMatches(FleetServer.fromEntry(entry), _search.text))
            entry,
      ];
      final selected = [
        for (final entry in pending)
          if (_selected.contains(entry.serverId)) entry.serverId,
      ];
      final error = _error;

      final content = <Widget>[
        Semantics(
          header: true,
          child: Text(l10n.endpointsTitle, style: theme.textTheme.titleLarge),
        ),
        const SizedBox(height: 12),
        Text(l10n.endpointsBody),
        const SizedBox(height: 16),
        TextField(
          controller: _search,
          autofocus: true,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: l10n.endpointsSearch,
            prefixIcon: const Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 8),
        if (pending.isEmpty)
          _Empty(l10n.endpointsNoneLeft)
        else if (shown.isEmpty)
          _Empty(l10n.endpointsNoMatch)
        else
          for (final entry in shown)
            _EndpointRow(
              entry: entry,
              selected: _selected.contains(entry.serverId),
              onChanged: _busy
                  ? null
                  : (on) => setState(() {
                      if (on) {
                        _selected.add(entry.serverId);
                      } else {
                        _selected.remove(entry.serverId);
                      }
                    }),
            ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
      ];
      final actions = Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: OverflowBar(
          alignment: MainAxisAlignment.end,
          spacing: 8,
          overflowSpacing: 8,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(material.closeButtonLabel),
            ),
            OutlinedButton(
              onPressed: _busy || shown.isEmpty
                  ? null
                  : () => _confirm([for (final entry in shown) entry.serverId]),
              child: Text(l10n.endpointsConfirmAllShown),
            ),
            FilledButton(
              onPressed: _busy || selected.isEmpty
                  ? null
                  : () => _confirm(selected),
              child: Text(l10n.endpointsConfirmSelected(selected.length)),
            ),
          ],
        ),
      );

      // On a short screen (a landscape phone at large text) the actions
      // scroll with the rows, which they would otherwise squeeze to
      // nothing; elsewhere they stay in view under one scroll for the
      // text, the search and the rows (A11Y-09).
      return LayoutBuilder(
        builder: (context, box) {
          const padding = EdgeInsets.fromLTRB(24, 24, 24, 8);
          if (box.maxHeight < _pinnedActionsMinHeight) {
            return ListView(
              shrinkWrap: true,
              padding: padding,
              children: [...content, actions],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: padding,
                  children: content,
                ),
              ),
              actions,
            ],
          );
        },
      );
    },
  );
}

/// One server to confirm: its toggle, its name, and the endpoint the
/// confirmation pins.
class _EndpointRow extends StatelessWidget {
  const _EndpointRow({
    required this.entry,
    required this.selected,
    required this.onChanged,
  });

  final FleetEntry entry;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final route = entry.jumpRoute;
    final changed = entry.endpoint == EndpointConfirmation.changed;
    return CheckboxListTile(
      value: selected,
      onChanged: onChanged == null ? null : (on) => onChanged!(on ?? false),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(entry.label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(FleetServer.fromEntry(entry).address ?? entry.host),
          if (route != null)
            Text(l10n.endpointsRoute(route.join(l10n.endpointsRouteSeparator))),
          if (changed)
            Text(
              l10n.endpointsChanged,
              style: TextStyle(color: theme.colorScheme.error),
            ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}
