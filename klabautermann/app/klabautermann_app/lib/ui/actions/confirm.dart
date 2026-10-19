import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show ActionConfirmation, ConfirmationTier;

import '../../l10n/app_localizations.dart';

/// The preview's confirmation (SAF-05, 03 §8.6), fully keyboard-operable:
/// tier 1 names the target and Run confirms; tier 2 asks for the target's
/// name typed exactly, and Run and Enter act only once it matches. Escape
/// and Cancel close without acting. [onConfirm] gets what [RunAction]
/// sends, [onCancel] closes the preview.
class ActionConfirm extends StatefulWidget {
  const ActionConfirm({
    super.key,
    required this.tier,
    required this.targetName,
    required this.onConfirm,
    required this.onCancel,
  });

  final ConfirmationTier tier;
  final String targetName;
  final ValueChanged<ActionConfirmation> onConfirm;
  final VoidCallback onCancel;

  @override
  State<ActionConfirm> createState() => _ActionConfirmState();
}

class _ActionConfirmState extends State<ActionConfirm> {
  final _phrase = TextEditingController();

  bool get _typed => widget.tier == ConfirmationTier.typedPhrase;

  bool get _ready => !_typed || _phrase.text == widget.targetName;

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  void _confirm() {
    if (!_ready) return;
    widget.onConfirm(
      ActionConfirmation(
        tier: widget.tier,
        phrase: _typed ? _phrase.text : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          if (_typed)
            TextField(
              controller: _phrase,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l10n.actionConfirmType(widget.targetName),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _confirm(),
            )
          else
            Text(l10n.actionConfirmNames(widget.targetName)),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                onPressed: widget.onCancel,
                child: Text(l10n.actionConfirmCancel),
              ),
              FilledButton(
                autofocus: !_typed,
                onPressed: _ready ? _confirm : null,
                child: Text(l10n.actionConfirmRun),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
