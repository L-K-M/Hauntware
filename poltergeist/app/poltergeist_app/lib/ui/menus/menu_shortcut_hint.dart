import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart';

import '../../services/registered_command.dart';
import '../../theme/app_theme.dart';

/// The trailing shortcut hint a registry menu row shows (10 §8): the
/// command's first registered activator — the chord layer's own binding,
/// so hint and dispatch cannot drift — spelled by the shared formatter,
/// in the chrome's secondary text colour so the label leads. Display
/// only: the chord layer dispatches.
class MenuShortcutHint extends StatelessWidget {
  const MenuShortcutHint(this.activator, {super.key, this.enabled = true});

  /// The hint for [command]'s first activator on [platform], or null
  /// when it has none.
  static MenuShortcutHint? forCommand(
    RegisteredCommand command,
    TargetPlatform platform,
  ) {
    final activators = command.activators?.call(platform);
    if (activators == null || activators.isEmpty) return null;
    return MenuShortcutHint(activators.first, enabled: command.enabled());
  }

  final ShortcutActivator activator;

  /// A disabled row dims its hint with its label.
  final bool enabled;

  @override
  Widget build(BuildContext context) => GhostShortcutHint(
    activator,
    enabled: enabled,
    color: PoltergeistChrome.of(context).secondaryText,
  );
}
