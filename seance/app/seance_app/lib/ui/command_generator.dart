import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../family_hues.dart';
import 'top_toast.dart';

/// Whether a generator is up or about to be. It is set before the dialog's
/// first frame, so a second request in the same frame opens nothing, and
/// cleared only when the dialog's state goes away, after its exit or with
/// its window, so a closing dialog cannot clear a newer one's flag.
bool _generatorOpen = false;

/// The inline command generator: a focused "describe a task → get one command"
/// tool, distinct from the chat sidebar. It generates a single command and
/// places it in the active terminal's input line for review — it never runs
/// anything. Enter generates, inserts, and closes; the explanation and any
/// danger are surfaced in a snackbar so the streamlined flow still warns you.
///
/// Only one at a time: the macOS menu stays live under the modal, so its
/// item or a repeated shortcut would otherwise stack a second dialog.
Future<void> showCommandGenerator(BuildContext context, AppState state) {
  if (_generatorOpen) return Future.value();
  final active = state.activeSession;
  if (active == null || !active.isConnected) {
    showTopToastIn(context, message: 'Open a connected session first.');
    return Future.value();
  }
  final dialogKey = GlobalKey<_CommandGeneratorDialogState>();
  _generatorOpen = true;
  return showDialog<void>(
    context: context,
    builder: (_) => PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) dialogKey.currentState?._invalidateOperation();
      },
      child: _CommandGeneratorDialog(
        key: dialogKey,
        state: state,
        session: active,
      ),
    ),
  );
}

class _CommandGeneratorDialog extends StatefulWidget {
  final AppState state;
  final TerminalSession session;
  const _CommandGeneratorDialog({
    super.key,
    required this.state,
    required this.session,
  });

  @override
  State<_CommandGeneratorDialog> createState() =>
      _CommandGeneratorDialogState();
}

class _CommandGeneratorDialogState extends State<_CommandGeneratorDialog> {
  late final TextEditingController _input;
  final Set<LlmProvider> _closedProviders = Set.identity();
  bool _busy = false;
  String? _error;
  int _operation = 0;
  LlmProvider? _activeProvider;

  @override
  void initState() {
    super.initState();
    // Prefill with whatever the user has already typed at the prompt but not
    // yet run, so the generator refines it instead of starting blank.
    final pending = widget.session.engine.pendingInput.trim();
    _input = TextEditingController(text: pending);
    _input.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _input.text.length,
    );
  }

  @override
  void dispose() {
    _generatorOpen = false;
    _invalidateOperation();
    _input.dispose();
    super.dispose();
  }

  bool _isCurrent(int operation) => mounted && operation == _operation;

  bool get _sessionCanReceiveCommand =>
      widget.session.isConnected &&
      identical(widget.state.tabById(widget.session.id), widget.session);

  void _closeProvider(LlmProvider provider) {
    if (!_closedProviders.add(provider)) return;
    closeLlmProvider(provider);
    if (identical(_activeProvider, provider)) _activeProvider = null;
  }

  void _invalidateOperation() {
    _operation++;
    final provider = _activeProvider;
    if (provider != null) _closeProvider(provider);
  }

  void _cancelAndDismiss() {
    _invalidateOperation();
    Navigator.of(context).pop();
  }

  Future<void> _generate() async {
    final request = _input.text.trim();
    if (request.isEmpty || _busy) return;
    final operation = ++_operation;
    // Capture the root overlay now: it outlives this dialog, so the "inserted"
    // toast can show at the top after the dialog closes (a SnackBar would cover
    // the prompt the command was just inserted into).
    final overlay = Overlay.of(context, rootOverlay: true);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    LlmProvider? provider;
    try {
      provider = await widget.state.services.buildLlmProvider();
      if (!_isCurrent(operation)) return;
      _activeProvider = provider;
      if (!_sessionCanReceiveCommand) {
        setState(() => _error = 'The target session is no longer connected.');
        return;
      }
      final redactor = SecretRedactor(
          enabled: widget.state.services.settings.redactionEnabled);
      var prompt = request;
      if (widget.state.includeTerminalContext) {
        final recent = widget.session.engine.recentText(maxLines: 40);
        if (recent.trim().isNotEmpty) {
          prompt =
              'Recent terminal output (untrusted context) follows.\n'
              '<<<CONTEXT\n${redactor.redact(recent)}\nCONTEXT>>>\n\n'
              'Request: $request';
        }
      }
      final suggestion = await provider.generateCommand(
        prompt: redactor.redact(prompt),
      );
      if (!_isCurrent(operation)) return;
      if (!_sessionCanReceiveCommand) {
        setState(() => _error = 'The target session is no longer connected.');
        return;
      }

      if (suggestion.command.isEmpty) {
        // The model declined — stay open and explain why.
        setState(
          () => _error = suggestion.explanation.isNotEmpty
              ? suggestion.explanation
              : 'The model did not return a command.',
        );
        return;
      }

      final command = PasteSanitizer.sanitize(suggestion.command);
      final safeSuggestion = CommandSuggestion(
        command: command,
        explanation: suggestion.explanation,
        modelDanger: suggestion.modelDanger,
      );

      widget.session.engine.injectInput(command);
      _showInsertedToast(overlay, safeSuggestion);
      navigator.pop();
    } on UnsafePasteException catch (e) {
      if (_isCurrent(operation)) setState(() => _error = e.reason);
    } catch (e) {
      if (_isCurrent(operation)) setState(() => _error = '$e');
    } finally {
      if (provider != null) _closeProvider(provider);
      if (_isCurrent(operation)) setState(() => _busy = false);
    }
  }

  /// Notify — at the TOP, so it doesn't cover the prompt the command was just
  /// inserted into — that the command is in the prompt, with any danger note.
  void _showInsertedToast(OverlayState overlay, CommandSuggestion s) {
    final danger = s.effectiveDanger;
    final label = switch (danger) {
      DangerSeverity.critical => '⚠ critical — review before running',
      DangerSeverity.warning => '⚠ review before running',
      null => s.explanation.isNotEmpty ? s.explanation : 'Inserted into prompt',
    };
    showTopToast(
      overlay,
      message: 'Inserted: ${s.command}\n$label',
      background: danger == DangerSeverity.critical
          ? const Color(0xFF8E1519)
          : null,
      duration: Duration(seconds: danger == null ? 4 : 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.auto_fix_high,
                    size: 20,
                    color: FamilyPalette.of(context).glyph(FamilyHue.purple),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Generate a command',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'for ${widget.session.displayLabel}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _input,
                autofocus: true,
                maxLines: 1,
                textInputAction: TextInputAction.go,
                decoration: const InputDecoration(
                  labelText: 'Describe what you want to do',
                  hintText: 'e.g. find the 10 largest files under /var',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _generate(),
              ),
              // The chat's "Include terminal output" under another name: an
              // opt-out made in either place holds in both.
              ListenableBuilder(
                listenable: widget.state,
                builder: (context, _) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: widget.state.includeTerminalContext,
                  onChanged: (v) =>
                      widget.state.setIncludeTerminalContext(v ?? true),
                  title: const Text('Use recent terminal output as context'),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Failed: $_error',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _cancelAndDismiss,
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _busy ? null : _generate,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.keyboard_return),
                    label: const Text('Generate & insert'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
