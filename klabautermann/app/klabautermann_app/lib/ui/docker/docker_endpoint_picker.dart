import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../l10n/app_localizations.dart';
import '../access/access_panel.dart' show engineNameText;

/// The widest the picker grows at the default text size; socket paths are
/// short, and a wider menu only spreads its words apart.
const double _maxWidth = 480;

/// CN-09's socket picker (D54): which engine socket [serverId]'s Docker
/// endpoint uses, as chosen on this device. Automatic, one of the sockets
/// the probe found ([profile]), or a custom path typed in a dialog and
/// checked with [dockerSocketPathProblem] first. A change goes to the
/// engine at once, which resolves the endpoint again with it. When the
/// endpoint settled on another socket, or none, a line says the chosen
/// one did not answer, since the engine then tries the sockets it found.
/// Under it, CN-16's `docker` program: the one on the exec `PATH`, or a
/// path typed in a dialog and checked with [dockerProgramPathProblem].
class DockerEndpointPicker extends StatelessWidget {
  const DockerEndpointPicker({
    super.key,
    required this.docker,
    required this.profile,
    required this.serverId,
  });

  final DockerController docker;
  final ValueListenable<HostProfile?> profile;
  final String serverId;

  Future<void> _choose(
    BuildContext context,
    DockerEndpointChoice choice,
  ) async {
    // Captured first: a choice can replace the tree this picker is in.
    final overlay = Overlay.of(context, rootOverlay: true);
    final notSaved = AppLocalizations.of(context).dockerSocketNotSaved;
    try {
      await docker.chooseEndpoint(serverId, choice);
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) showTopToast(overlay, message: notSaved);
    }
  }

  Future<void> _askCustom(BuildContext context, String? current) async {
    final l10n = AppLocalizations.of(context);
    final path = await showDialog<String>(
      context: context,
      builder: (context) => _PathDialog(
        initial: current,
        title: l10n.dockerSocketCustomTitle,
        body: l10n.dockerSocketCustomBody,
        field: l10n.dockerSocketCustomField,
        hint: l10n.dockerSocketCustomHint,
        problemOf: dockerSocketPathProblem,
      ),
    );
    if (path == null || !context.mounted) return;
    await _choose(context, DockerEndpointCustom(path));
  }

  Future<void> _chooseProgram(BuildContext context, String? program) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final notSaved = AppLocalizations.of(context).dockerProgramNotSaved;
    try {
      await docker.chooseProgram(serverId, program);
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) showTopToast(overlay, message: notSaved);
    }
  }

  Future<void> _askProgram(BuildContext context, String? current) async {
    final l10n = AppLocalizations.of(context);
    final path = await showDialog<String>(
      context: context,
      builder: (context) => _PathDialog(
        initial: current,
        title: l10n.dockerProgramTitle,
        body: l10n.dockerProgramBody,
        field: l10n.dockerProgramField,
        hint: l10n.dockerProgramHint,
        problemOf: dockerProgramPathProblem,
      ),
    );
    if (path == null || !context.mounted) return;
    await _chooseProgram(context, path);
  }

  @override
  Widget build(BuildContext context) {
    final endpoint = docker.endpointFor(serverId);
    return ListenableBuilder(
      listenable: Listenable.merge([docker.endpointChoices, profile, endpoint]),
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        final theme = Theme.of(context);
        final textScaler = MediaQuery.textScalerOf(context);
        final choice = docker.endpointChoices.choiceFor(serverId);
        final program = docker.endpointChoices.programFor(serverId);
        final options = _options(l10n, choice, profile.value);
        final notInUse = _notInUse(choice, endpoint.value);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: textScaler.scale(_maxWidth),
              ),
              child: Row(
                spacing: 12,
                children: [
                  Text(l10n.dockerSocketLabel),
                  Flexible(
                    child: DropdownButton<_Option>(
                      isExpanded: true,
                      value: options.firstWhere((o) => o.choice == choice),
                      items: [
                        for (final option in options)
                          DropdownMenuItem(
                            value: option,
                            child: Text(
                              option.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (option) {
                        if (option == null) return;
                        final picked = option.choice;
                        if (picked == null) {
                          unawaited(
                            _askCustom(context, switch (choice) {
                              DockerEndpointCustom(:final socketPath) =>
                                socketPath,
                              _ => null,
                            }),
                          );
                        } else {
                          unawaited(_choose(context, picked));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            if (notInUse != null)
              MergeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        Icons.warning_amber_outlined,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                    ),
                    Flexible(
                      child: Text(
                        l10n.dockerSocketNotInUse(notInUse),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(l10n.dockerProgramLabel),
                Text(program ?? l10n.dockerProgramDefault),
                TextButton(
                  onPressed: () => unawaited(_askProgram(context, program)),
                  child: Text(
                    l10n.dockerProgramChange,
                    semanticsLabel: l10n.dockerProgramChangeLabel,
                  ),
                ),
                if (program != null)
                  TextButton(
                    onPressed: () => unawaited(_chooseProgram(context, null)),
                    child: Text(l10n.dockerProgramReset),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// Automatic, each socket the probe found, the current choice when the
  /// probe does not list it, then the custom path action.
  static List<_Option> _options(
    AppLocalizations l10n,
    DockerEndpointChoice choice,
    HostProfile? profile,
  ) {
    final engines = profile == null
        ? const <EngineEndpoint>[]
        : evaluateAccess(profile).engines;
    final detected = [
      for (final engine in engines)
        _Option(
          DockerEndpointDetected(engine.socket.path),
          l10n.accessEngineAt(engineNameText(l10n, engine), engine.socket.path),
        ),
    ];
    return [
      _Option(const DockerEndpointAuto(), l10n.dockerSocketAutomatic),
      ...detected,
      if (choice case DockerEndpointSocket(
        :final socketPath,
      ) when !detected.any((o) => o.choice == choice))
        _Option(choice, switch (choice) {
          DockerEndpointCustom() => l10n.dockerSocketCustomCurrent(socketPath),
          DockerEndpointDetected() => socketPath,
        }),
      _Option(null, l10n.dockerSocketCustomAction),
    ];
  }

  /// The chosen socket's path when the endpoint settled on another socket
  /// or on none; null otherwise. An invalid path or docker program has
  /// the gate's own words.
  static String? _notInUse(
    DockerEndpointChoice choice,
    DockerEndpointState? endpoint,
  ) {
    if (choice is! DockerEndpointSocket || endpoint == null) return null;
    if (endpoint.choice != choice) return null;
    return switch (endpoint) {
      DockerEndpointState(phase: DockerEndpointPhase.ready, :final route?)
          when route.socketPath != choice.socketPath =>
        choice.socketPath,
      DockerEndpointState(
        phase: DockerEndpointPhase.failed,
        :final failure,
        :final route,
      )
          when failure != DockerEndpointFailure.invalidChoice &&
              failure != DockerEndpointFailure.invalidProgram &&
              route?.socketPath != choice.socketPath =>
        choice.socketPath,
      _ => null,
    };
  }
}

/// One picker entry: a choice, or the custom path action (null).
@immutable
final class _Option {
  const _Option(this.choice, this.label);

  final DockerEndpointChoice? choice;
  final String label;

  @override
  bool operator ==(Object other) => other is _Option && other.choice == choice;

  @override
  int get hashCode => choice.hashCode;
}

/// Asks for a socket or program path, checked with [problemOf] as the
/// engine checks it before it is returned; null when cancelled.
class _PathDialog extends StatefulWidget {
  const _PathDialog({
    this.initial,
    required this.title,
    required this.body,
    required this.field,
    required this.hint,
    required this.problemOf,
  });

  final String? initial;
  final String title, body, field, hint;
  final DockerSocketPathProblem? Function(String path) problemOf;

  @override
  State<_PathDialog> createState() => _PathDialogState();
}

class _PathDialogState extends State<_PathDialog> {
  late final TextEditingController _path = TextEditingController(
    text: widget.initial,
  );
  DockerSocketPathProblem? _problem;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  void _submit() {
    final path = _path.text;
    final problem = widget.problemOf(path);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(context).pop(path);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 16,
        children: [
          Text(widget.body),
          TextField(
            controller: _path,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: widget.field,
              hintText: widget.hint,
              errorText: switch (_problem) {
                DockerSocketPathProblem.notAbsolute =>
                  l10n.dockerSocketPathNotAbsolute,
                DockerSocketPathProblem.unsafeCharacter =>
                  l10n.dockerSocketPathUnsafe,
                null => null,
              },
            ),
            onChanged: (_) {
              if (_problem != null) setState(() => _problem = null);
            },
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dockerSocketCustomCancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.dockerSocketCustomUse),
        ),
      ],
    );
  }
}
