/// The keyboard-interactive (RFC 4256) prompt Séance and Poltergeist raise
/// when a server asks questions during authentication, such as a password
/// and a one-time code.
///
/// Neither app's truth types cross this boundary. Séance's
/// `KeyboardInteractiveChallenge` lives in `seance_core` and Poltergeist's
/// `KeyboardInteractivePromptData` in its engine protocol, so each app maps
/// its own onto [GhostKeyboardPrompt] in its adapter. Wording comes in
/// through [GhostKeyboardInteractiveStrings] (docs/design/
/// ghost-servers-part1.md §3 to §5).
library;

import 'package:flutter/material.dart';

/// What the prompt shows: the trusted endpoint the challenge came from, and
/// the server's own words, which are untrusted.
final class GhostKeyboardPrompt {
  const GhostKeyboardPrompt({
    this.username,
    required this.host,
    required this.port,
    required this.name,
    required this.instruction,
    required this.prompts,
  });

  /// The account being authenticated, where the host knows it.
  /// Klabautermann's engine request names none.
  final String? username;

  /// The host as configured. A bare IPv6 address is bracketed for display.
  final String host;
  final int port;

  /// The server's challenge name and instruction; either may be empty.
  final String name;
  final String instruction;

  /// The server's questions, one answer field each, in answer order.
  final List<String> prompts;
}

/// The prompt's words, as one bag. The defaults are Séance's, so Séance
/// passes nothing; a host with localized copy passes its own.
final class GhostKeyboardInteractiveStrings {
  const GhostKeyboardInteractiveStrings({
    this.title = 'Authentication',
    this.requestFrom = 'Request from',
    this.serverMessage = 'Server message',
    this.endpoint = _endpoint,
    this.showAnswer = 'Show answer',
    this.hideAnswer = 'Hide answer',
    this.cancel = 'Cancel',
    this.submit = 'Submit',
  });

  /// The dialog's title.
  final String title;

  /// The label over the trusted endpoint.
  final String requestFrom;

  /// The label over the server's name and instruction.
  final String serverMessage;

  /// The trusted endpoint line, from the username where there is one, the
  /// host (a bare IPv6 address already bracketed) and the port.
  final String Function(String? username, String host, int port) endpoint;

  /// The tooltips that reveal and re-mask an answer.
  final String showAnswer;
  final String hideAnswer;

  /// The verbs that decline and answer.
  final String cancel;
  final String submit;
}

String _endpoint(String? username, String host, int port) =>
    username == null ? '$host:$port' : '$username@$host:$port';

/// The host as the endpoint line shows it: a bare IPv6 address gains
/// brackets, so its colons cannot be read as the port separator.
String _displayHost(String host) =>
    host.contains(':') && !(host.startsWith('[') && host.endsWith(']'))
    ? '[$host]'
    : host;

/// Prompts for keyboard-interactive auth (e.g. a 2FA/TOTP code). Returns one
/// answer per prompt, in order. An empty list cancels the attempt.
///
/// With [submitOnEnter], Enter moves from an answer to the next and submits
/// from the last. Without it the fields keep Flutter's default Enter
/// handling and only the buttons answer; Séance passes false until it
/// adopts the focus chain (docs/design/ghost-servers-part1.md §6).
/// [dialogKey] keys the dialog, so a host that withdraws a prompt can find
/// its route.
Future<List<String>> showGhostKeyboardInteractiveDialog(
  BuildContext context,
  GhostKeyboardPrompt prompt, {
  GhostKeyboardInteractiveStrings strings =
      const GhostKeyboardInteractiveStrings(),
  GlobalKey? dialogKey,
  bool submitOnEnter = true,
}) async {
  final result = await showDialog<List<String>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _KeyboardInteractiveDialog(
      key: dialogKey,
      prompt: prompt,
      strings: strings,
      submitOnEnter: submitOnEnter,
    ),
  );
  return result ?? const <String>[];
}

/// Owns the prompt controllers in its [State] so they are disposed in
/// [State.dispose] — after the route's exit animation, once the fields are
/// truly unmounted. Disposing right after `await showDialog(...)` is too
/// early: the fields stay mounted through the reverse transition and the
/// framework can still write to a controller (e.g. `clearComposing()` when
/// the focused field loses focus) — a use-after-dispose that throws in debug
/// builds whenever an IME composing region is active. Same lifecycle as
/// Séance's snippet placeholder dialog (regression there:
/// test/placeholder_dialog_test.dart).
class _KeyboardInteractiveDialog extends StatefulWidget {
  const _KeyboardInteractiveDialog({
    super.key,
    required this.prompt,
    required this.strings,
    required this.submitOnEnter,
  });

  final GhostKeyboardPrompt prompt;
  final GhostKeyboardInteractiveStrings strings;
  final bool submitOnEnter;

  @override
  State<_KeyboardInteractiveDialog> createState() =>
      _KeyboardInteractiveDialogState();
}

class _KeyboardInteractiveDialogState
    extends State<_KeyboardInteractiveDialog> {
  late final List<TextEditingController> _controllers = [
    for (final _ in widget.prompt.prompts) TextEditingController(),
  ];

  final Set<int> _revealed = {};

  // Only the dialog's own route may be popped: a rapid second activation
  // during the exit animation — or a callback from a dialog obscured by a
  // newer route — would otherwise pop whatever sits below instead.
  void _close(List<String> answers) {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.pop(context, answers);
  }

  void _submit() =>
      _close([for (final controller in _controllers) controller.text]);

  bool _isLast(int i) => i == widget.prompt.prompts.length - 1;

  // The submitOnEnter focus chain: Enter advances, the last answer submits.
  TextInputAction _enterAction(int i) =>
      _isLast(i) ? TextInputAction.done : TextInputAction.next;

  void _onEnter(int i) {
    if (_isLast(i)) {
      _submit();
      return;
    }

    FocusScope.of(context).nextFocus();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    final strings = widget.strings;
    final submitOnEnter = widget.submitOnEnter;
    return AlertDialog(
      // Long challenges must remain reachable above the software keyboard.
      scrollable: true,
      title: Text(strings.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.requestFrom,
            style: Theme.of(context).textTheme.labelMedium,
          ),
          SelectableText(
            strings.endpoint(
              prompt.username,
              _displayHost(prompt.host),
              prompt.port,
            ),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          if (prompt.name.isNotEmpty || prompt.instruction.isNotEmpty) ...[
            Text(
              strings.serverMessage,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            if (prompt.name.isNotEmpty) Text(prompt.name),
            if (prompt.instruction.isNotEmpty) Text(prompt.instruction),
            const SizedBox(height: 12),
          ],
          for (var i = 0; i < prompt.prompts.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _controllers[i],
                autofocus: i == 0,
                keyboardType: TextInputType.visiblePassword,
                // Echo metadata is absent; reveal only on explicit user request.
                obscureText: !_revealed.contains(i),
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                textInputAction: submitOnEnter ? _enterAction(i) : null,
                onSubmitted: submitOnEnter ? (_) => _onEnter(i) : null,
                decoration: InputDecoration(
                  labelText: prompt.prompts[i],
                  suffixIcon: IconButton(
                    tooltip: _revealed.contains(i)
                        ? strings.hideAnswer
                        : strings.showAnswer,
                    icon: Icon(
                      _revealed.contains(i)
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () => setState(() {
                      if (!_revealed.remove(i)) _revealed.add(i);
                    }),
                  ),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => _close(const <String>[]),
          child: Text(strings.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(strings.submit)),
      ],
    );
  }
}
