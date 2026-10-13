import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show formatShortcutActivator;

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../../theme/app_theme.dart';
import '../menus/app_menus.dart' show appMenuTitle;

/// Help ▸ Keyboard Shortcuts (10 §8): every registered command that has a
/// chord, grouped by the menu it lives in — generated from the registry
/// (D21), so the sheet can never drift from what the keys actually do.
/// [views] add the keys a view binds for itself, each under its own
/// heading after the menus.
Future<void> showKeyboardShortcutsDialog(
  BuildContext context,
  List<RegisteredCommand> commands, {
  List<ViewShortcuts> views = const [],
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _KeyboardShortcutsDialog(commands: commands, views: views),
  );
}

class _KeyboardShortcutsDialog extends StatelessWidget {
  const _KeyboardShortcutsDialog({required this.commands, required this.views});

  final List<RegisteredCommand> commands;
  final List<ViewShortcuts> views;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final platform = theme.platform;

    final grouped = <AppMenuId?, List<(String, String)>>{};
    for (final command in commands) {
      final activators = command.activators?.call(platform);
      if (activators == null || activators.isEmpty) continue;
      final chords = [
        for (final activator in activators)
          ?formatShortcutActivator(activator, platform),
      ];
      if (chords.isEmpty) continue;
      grouped
          .putIfAbsent(command.menuPlacement?.menu, () => [])
          .add((command.label(l10n), chords.join('  ·  ')));
    }
    // Menus first, then each view's own keys, then the commands no menu
    // holds.
    final sections = <(String, List<(String, String)>)>[
      for (final id in AppMenuId.values)
        if (grouped[id] case final rows?) (appMenuTitle(id, l10n), rows),
      for (final view in views)
        if (_viewRows(view, l10n, platform) case final rows
            when rows.isNotEmpty)
          (view.title(l10n), rows),
      if (grouped[null] case final rows?) (l10n.helpShortcutsOtherGroup, rows),
    ];

    return Dialog(
      key: const ValueKey('help.shortcuts.dialog'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.helpKeyboardShortcutsLabel,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                shrinkWrap: true,
                children: [
                  for (final (title, rows) in sections) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 14, bottom: 4),
                      child: Text(
                        title,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: chrome.secondaryText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final (label, chord) in rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                label,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            Text(
                              chord,
                              style: poltergeistMonoTextStyle.copyWith(
                                fontSize: 12,
                                color: chrome.secondaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// [view]'s keys as label and chord, leaving out any chord the platform
  /// has no spelling for.
  static List<(String, String)> _viewRows(
    ViewShortcuts view,
    AppLocalizations l10n,
    TargetPlatform platform,
  ) => [
    for (final key in view.keys)
      if (formatShortcutActivator(key.activator, platform) case final chord?)
        (key.label(l10n), chord),
  ];
}
