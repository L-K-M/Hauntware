import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, PlatformException;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/fleet_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart' show klabautermannThemeStyle;

/// The widest the Access tab's column grows at the default text size; it
/// grows with the text scale, so large text keeps its line length.
const double _maxWidth = 760;

/// The gap between the tab's sections and rows.
const double _gap = 12;

/// A row's status icon, and the gap after it.
const double _iconSize = 20;
const double _iconGap = 12;

/// The indent that lines a row's details up under its title, past the
/// status icon.
const double _detailIndent = _iconSize + _iconGap;

/// A word the shell reads as itself, which the copied command keeps bare
/// for legibility; anything else goes through [quoteShellWord]. `=` and
/// `%` are left out: zsh expands a leading `=word` to a command path.
final _plainWord = RegExp(r'^[A-Za-z0-9_./:@+,-]+$');

/// [fix] as one line to paste into a shell on the server: its elevation
/// prefix, then each word, quoted where the shell would split or expand
/// it (03 §8.8). The access check builds fixes from validated names only;
/// the quoting keeps a pasted line literal regardless.
String fixCommandText(AccessFix fix) => fix.commandLine
    .map((word) => _plainWord.hasMatch(word) ? word : quoteShellWord(word))
    .join(' ');

/// The Access tab (CN-24, 03 §10.4, D51): what the login account may do
/// on [serverId], from the access check (K04) over the probe's
/// [HostProfile], with SAF-08's root-equivalence notice. Each row shows
/// its state in an icon and a word, its reason and, where one exists, a
/// fix command the user copies and runs; the app never runs it. Until the
/// probe answers every row is unknown, never zero. Read-only: the
/// runtime (CN-09) is detected, and choosing one arrives with M3 (D54).
class AccessPanel extends StatelessWidget {
  const AccessPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    this.focusNode,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// Focuses the tab as a whole, ahead of its controls, so the next Tab
  /// press reaches its first one; it is no stop of its own.
  final FocusNode? focusNode;

  // One unit in Tab order: the tab's controls come together rather than
  // interleaved, row by row, with a pane's controls beside it.
  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    child: Focus(
      focusNode: focusNode,
      skipTraversal: true,
      child: ValueListenableBuilder<HostProfile?>(
        valueListenable: monitoring.profileFor(serverId),
        // Keyed: the workspace reuses this panel for the next server, whose
        // rows start with nothing copied and the column at its top.
        builder: (context, profile, _) =>
            _AccessBody(key: ValueKey(serverId), profile: profile),
      ),
    ),
  );
}

/// The Access tab as a pushed screen, where a phone reaches it from a
/// hidden panel (03 §10.5). The server stays open under it.
class AccessPage extends StatelessWidget {
  const AccessPage({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.serverId,
    required this.serverName,
  });

  final FleetController fleet;
  final MonitoringController monitoring;
  final String serverId;
  final String serverName;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(AppLocalizations.of(context).accessPageTitle(serverName)),
    ),
    // A server leaving the fleet takes its profile listenable with it
    // (SYN-08) and closes this screen with the server's; until the screen
    // has gone, the panel reads the listenable again on each fleet
    // change, as the server screen under it does.
    body: SafeArea(
      child: ListenableBuilder(
        listenable: fleet,
        builder: (context, _) =>
            AccessPanel(monitoring: monitoring, serverId: serverId),
      ),
    ),
  );
}

/// What the tab's last copy did.
enum _CopyOutcome { copied, failed }

/// The tab's last copy: which row's command, and whether the clipboard
/// took it.
typedef _Copy = ({AccessItem item, String command, _CopyOutcome outcome});

class _AccessBody extends StatefulWidget {
  const _AccessBody({super.key, required this.profile});

  final HostProfile? profile;

  @override
  State<_AccessBody> createState() => _AccessBodyState();
}

class _AccessBodyState extends State<_AccessBody> {
  /// One for the whole tab: the clipboard holds only the last text
  /// copied, so a copy clears every other row's line about an earlier
  /// one, which a user could otherwise paste into a root shell.
  _Copy? _lastCopy;

  Future<void> _copy(AccessItem item, String command) async {
    var outcome = _CopyOutcome.copied;
    try {
      await Clipboard.setData(ClipboardData(text: command));
    } on PlatformException {
      // Windows refuses while another process holds the clipboard
      // (OpenClipboard fails). The clipboard keeps its earlier text, so
      // the row says the copy failed rather than leave the screen as it was.
      outcome = _CopyOutcome.failed;
    }
    if (!mounted) return;
    setState(
      () => _lastCopy = (item: item, command: command, outcome: outcome),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final profile = widget.profile;
    final access = profile == null ? null : evaluateAccess(profile);
    final rootShellNote = access == null
        ? null
        : _rootShellNote(l10n, access.row(AccessItem.sudoNoPassword));
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: EdgeInsets.all(box.maxWidth >= 600 ? 20 : 16),
        child: Align(
          alignment: AlignmentDirectional.topStart,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: textScaler.scale(_maxWidth)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: _gap,
              children: [
                _Note(icon: Icons.info_outline, text: l10n.accessNeverRuns),
                // SAF-08's notice (03 §8.4) heads the tab whatever the rows
                // say, so no fix granting Docker or sudo rights shows
                // without it.
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _Note(
                      icon: Icons.shield_outlined,
                      title: l10n.accessRootEquivalenceTitle,
                      text: l10n.accessRootEquivalenceBody,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
                if (profile == null || access == null) ...[
                  _Note(icon: Icons.schedule, text: l10n.accessNotChecked),
                  for (final item in AccessItem.values)
                    _AccessRowTile(
                      item: item,
                      status: AccessStatus.unknown,
                      reason: l10n.accessRowNotChecked,
                    ),
                ] else
                  for (final row in access.rows)
                    _AccessRowTile(
                      item: row.item,
                      status: row.status,
                      reason: _reasonText(l10n, row.reason, profile),
                      rootEquivalent: row.rootEquivalent,
                      fix: row.fix,
                      lastCopy: _lastCopy,
                      onCopy: (command) => _copy(row.item, command),
                      rootShellNote: rootShellNote,
                      details: row.item == AccessItem.runtime
                          ? _engineLines(context, access.engines)
                          : const [],
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An icon beside a paragraph under an optional heading, read as one
/// node; the icon is decoration.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.title, this.color});

  final IconData icon;
  final String text;
  final String? title;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = this.color ?? theme.colorScheme.onSurfaceVariant;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          ExcludeSemantics(
            child: Icon(icon, size: _iconSize, color: color),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                if (title case final title?)
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(color: color),
                    ),
                  ),
                Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One access-check row: the state as an icon and a word (never colour
/// alone, 03 §10.10), the reason, the SAF-08 badge, and the fix to copy.
class _AccessRowTile extends StatelessWidget {
  const _AccessRowTile({
    required this.item,
    required this.status,
    required this.reason,
    this.rootEquivalent = false,
    this.fix,
    this.lastCopy,
    this.onCopy,
    this.rootShellNote,
    this.details = const [],
  });

  final AccessItem item;
  final AccessStatus status;
  final String reason;
  final bool rootEquivalent;
  final AccessFix? fix;

  /// The tab's last copy, which the row words while it is the fix shown.
  final _Copy? lastCopy;

  /// Copies the fix's command; a row without a fix needs none.
  final void Function(String command)? onCopy;

  /// The note under a [FixElevation.rootShell] fix, which carries no
  /// prefix: K04 gives one both when the probe found neither sudo nor doas
  /// and when it did not answer.
  final String? rootShellNote;

  /// Lines under the reason: the runtime row's engines.
  final List<Widget> details;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color, word) = switch (status) {
      AccessStatus.ok => (
        Icons.check_circle_outline,
        scheme.primary,
        l10n.accessStatusOk,
      ),
      AccessStatus.missing => (
        Icons.cancel_outlined,
        scheme.error,
        l10n.accessStatusMissing,
      ),
      AccessStatus.unknown => (
        Icons.help_outline,
        scheme.onSurfaceVariant,
        l10n.accessStatusUnknown,
      ),
    };
    final fix = this.fix;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: _iconGap,
                children: [
                  ExcludeSemantics(
                    child: Icon(icon, size: _iconSize, color: color),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 4,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _itemTitle(l10n, item),
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              word,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: color,
                              ),
                            ),
                            if (rootEquivalent) const _RootBadge(),
                          ],
                        ),
                        Text(reason, style: theme.textTheme.bodyMedium),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (details.isNotEmpty || fix != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: _detailIndent),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    ...details,
                    if (fix != null) ..._fixLines(context, l10n, fix),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _fixLines(
    BuildContext context,
    AppLocalizations l10n,
    AccessFix fix,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final command = fixCommandText(fix);
    final copy = lastCopy;
    final outcome = copy?.item == item && copy?.command == command
        ? copy?.outcome
        : null;
    final onCopy = this.onCopy;
    final mono = klabautermannThemeStyle.monoFontFamilies;
    return [
      // The SAF-08 notice beside docker-group advice (03 §8.4).
      if (item == AccessItem.dockerSocket)
        _Note(
          icon: Icons.warning_amber_outlined,
          text: l10n.accessDockerGroupWarning,
          color: scheme.onSurface,
        ),
      DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SelectableText(
            command,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: mono.first,
              fontFamilyFallback: mono.skip(1).toList(growable: false),
              color: scheme.onSurface,
            ),
          ),
        ),
      ),
      if (rootShellNote case final note?
          when fix.elevation == FixElevation.rootShell)
        Text(note, style: theme.textTheme.bodySmall),
      // The journal and Docker fixes add the account to a group.
      if (item case AccessItem.journal || AccessItem.dockerSocket)
        Text(l10n.accessFixNextLogin, style: theme.textTheme.bodySmall),
      Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: onCopy == null ? null : () => onCopy(command),
            icon: Icon(
              outcome == _CopyOutcome.copied
                  ? Icons.check
                  : Icons.copy_outlined,
              size: 18,
            ),
            // Read with its row's name: a host shows several such buttons.
            label: Text(
              l10n.accessFixCopy,
              semanticsLabel: l10n.accessFixCopyLabel(_itemTitle(l10n, item)),
            ),
          ),
          // Announced as it appears; the app has run nothing.
          if (outcome == _CopyOutcome.copied)
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.accessFixCopied,
                style: theme.textTheme.bodySmall,
              ),
            ),
          // Announced too: the clipboard still holds older text, which
          // must not be pasted as this fix.
          if (outcome == _CopyOutcome.failed)
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.accessFixCopyFailed,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
        ],
      ),
    ];
  }
}

/// SAF-08's badge beside a root-equivalent right.
class _RootBadge extends StatelessWidget {
  const _RootBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.warning_amber_outlined,
                size: 14,
                color: scheme.onErrorContainer,
              ),
            ),
            Flexible(
              child: Text(
                AppLocalizations.of(context).accessRootEquivalentBadge,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line pair per engine socket: which engine and where, then whether
/// the account can use it and what that equals (SAF-08). A `podman-docker`
/// install may serve the Docker path, which the API tells once M3 connects.
List<Widget> _engineLines(BuildContext context, List<EngineEndpoint> engines) {
  final l10n = AppLocalizations.of(context);
  final theme = Theme.of(context);
  return [
    for (final engine in engines)
      MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.accessEngineAt(
                engineNameText(l10n, engine),
                engine.socket.path,
              ),
              style: theme.textTheme.bodyMedium,
            ),
            Text(switch ((engine.socket.writable, engine.mode)) {
              (false, _) => l10n.accessEngineNotUsable,
              (true, EngineMode.rootful) => l10n.accessEngineUsableRootful,
              (true, EngineMode.rootless) => l10n.accessEngineUsableRootless,
            }, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    if (engines.any((e) => e.runtime == EngineRuntime.docker))
      Text(l10n.accessRuntimeAlias, style: theme.textTheme.bodySmall),
  ];
}

/// [engine]'s runtime and mode in words, such as "Docker, rootful": the
/// Access tab's engine lines and the server header's runtime.
String engineNameText(AppLocalizations l10n, EngineEndpoint engine) =>
    engineModeText(l10n, engine.runtime, engine.mode);

/// [runtime] and [mode] in words, such as "Docker, rootful": a detected
/// engine's ([engineNameText]) or the one a Docker route reaches.
String engineModeText(
  AppLocalizations l10n,
  EngineRuntime runtime,
  EngineMode mode,
) => switch ((runtime, mode)) {
  (EngineRuntime.docker, EngineMode.rootful) => l10n.accessEngineDockerRootful,
  (EngineRuntime.docker, EngineMode.rootless) =>
    l10n.accessEngineDockerRootless,
  (EngineRuntime.podman, EngineMode.rootful) => l10n.accessEnginePodmanRootful,
  (EngineRuntime.podman, EngineMode.rootless) =>
    l10n.accessEnginePodmanRootless,
};

/// Says the server lacks sudo and doas only when the probe found neither
/// ([sudo] is the elevation row); an unanswered elevation stays unknown.
String _rootShellNote(AppLocalizations l10n, AccessRow sudo) =>
    sudo.reason == AccessReason.noElevationTool
    ? l10n.accessFixRootShell
    : l10n.accessFixElevationUnknown;

String _itemTitle(AppLocalizations l10n, AccessItem item) => switch (item) {
  AccessItem.sudoNoPassword => l10n.accessItemSudo,
  AccessItem.journal => l10n.accessItemJournal,
  AccessItem.dockerSocket => l10n.accessItemDockerSocket,
  AccessItem.streamlocal => l10n.accessItemStreamlocal,
  AccessItem.composePlugin => l10n.accessItemCompose,
  AccessItem.systemd => l10n.accessItemSystemd,
  AccessItem.runtime => l10n.accessItemRuntime,
};

String _reasonText(
  AppLocalizations l10n,
  AccessReason reason,
  HostProfile profile,
) {
  // The access check gives a version reason only with a version.
  if (profile.systemdVersion case final version?) {
    switch (reason) {
      case AccessReason.systemdJson:
        return l10n.accessReasonSystemdJson(version);
      case AccessReason.systemdTextFallback:
        return l10n.accessReasonSystemdTextFallback(version);
      case AccessReason.systemdOlderThanTested:
        return l10n.accessReasonSystemdOlderThanTested(version);
      default:
        break;
    }
  }

  return switch (reason) {
    AccessReason.probeAreaUnavailable => l10n.accessReasonProbeUnavailable,
    AccessReason.rootLogin => l10n.accessReasonRootLogin,
    AccessReason.sudoNoPassword => l10n.accessReasonSudoNoPassword,
    AccessReason.doasNoPassword => l10n.accessReasonDoasNoPassword,
    AccessReason.sudoNotPasswordless => l10n.accessReasonSudoNotPasswordless,
    AccessReason.doasNotPasswordless => l10n.accessReasonDoasNotPasswordless,
    AccessReason.noElevationTool => l10n.accessReasonNoElevationTool,
    AccessReason.journalGroup => l10n.accessReasonJournalGroup,
    AccessReason.notInJournalGroup => l10n.accessReasonNotInJournalGroup,
    AccessReason.noJournal => l10n.accessReasonNoJournal,
    AccessReason.rootfulSocket => l10n.accessReasonRootfulSocket,
    AccessReason.rootlessSocket => l10n.accessReasonRootlessSocket,
    AccessReason.socketNotWritable => l10n.accessReasonSocketNotWritable,
    AccessReason.noEngineSocket => l10n.accessReasonNoEngineSocket,
    AccessReason.pendingDockerSupport => l10n.accessReasonPendingDocker,
    AccessReason.systemdJson ||
    AccessReason.systemdTextFallback ||
    AccessReason.systemdOlderThanTested ||
    AccessReason.systemdVersionUnparsed =>
      l10n.accessReasonSystemdVersionUnparsed,
    AccessReason.notSystemd => l10n.accessReasonNotSystemd,
    AccessReason.enginesDetected => l10n.accessReasonEnginesDetected,
    AccessReason.engineCliWithoutSocket =>
      l10n.accessReasonEngineCliWithoutSocket,
    AccessReason.noEngine => l10n.accessReasonNoEngine,
  };
}
