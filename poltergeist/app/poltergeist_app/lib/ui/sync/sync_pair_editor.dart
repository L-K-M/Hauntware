// The saved-sync pair editor (05 §9, `sync.newSavedSync` / the plan
// view's options affordance): one dialog editing a SyncPair's full
// definition — name, both endpoints, direction × deletion policy, and
// the advanced rule fields — plus the per-side case-sensitivity
// overrides that live in pair state (§3: the remote side's only
// sensitivity input). The result is a [SyncPairEditorResult]; the
// caller decides whether to persist a bookmark, rescan an open
// session, or both.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../l10n/app_localizations.dart';
import '../../services/sync_plan_controller.dart' show SyncCaseOverrides;
import '../../services/uuid.dart';
import '../display_path.dart';
import 'sync_rules_edit_request.dart';

const String _unlistedServerId = 'sync-editor-unlisted-server';
final DateTime _unlistedServerTimestamp = DateTime.fromMillisecondsSinceEpoch(
  0,
  isUtc: true,
);

/// What the editor produces on save.
final class SyncPairEditorResult {
  const SyncPairEditorResult({required this.pair, this.caseOverrides});

  /// The full pair definition — `id` and `lastRunAt` carry over from
  /// the edited pair so a re-save never forks the favorite's identity.
  final SyncPair pair;

  /// The per-side case-sensitivity answers — pair state, not ruleset.
  final SyncCaseOverrides? caseOverrides;
}

/// `sync.newSavedSync` and the plan view's rules edit share this
/// dialog. [initial] seeds every field (null opens a fresh pair);
/// [servers] lists the identity-backed remote bookmarks the endpoint
/// pickers offer.
final class SyncPairEditorDialog extends StatefulWidget {
  const SyncPairEditorDialog({
    super.key,
    this.initial,
    this.initialCaseOverrides,
    this.initialDocrootWarning,
    this.initialDocrootPaths = const {},
    this.initialEditTarget = SyncRulesEditTarget.general,
    this.servers = const [],
    this.saveLabel,
  });

  final SyncPair? initial;

  /// The pair state's current per-side case answers, when the caller
  /// holds them (a live session has scanned; a sheet opened from the
  /// sidebar has not). They seed the two case fields so an unrelated
  /// save never resets a stored override to "auto".
  final SyncCaseOverrides? initialCaseOverrides;

  /// A plan-view warning to resolve immediately. Its suggestion is
  /// prefilled and the affected trash field receives focus.
  final SyncDocrootWarning? initialDocrootWarning;

  /// Scan paths for [initial], retained only while endpoints stay unchanged.
  final Map<SyncSide, SyncDocrootPathState> initialDocrootPaths;

  /// The advanced field a plan refusal asks the editor to reveal.
  final SyncRulesEditTarget initialEditTarget;

  /// Remote candidates — the bookmark store's identity-backed
  /// `remotePath` rows (a missing embedded identity has nothing a
  /// RemoteEndpoint can reference).
  final List<Bookmark> servers;

  /// The save verb's label — "Save" for a new favorite, "Save &
  /// Rescan" over a live session.
  final String? saveLabel;

  @override
  State<SyncPairEditorDialog> createState() => _SyncPairEditorDialogState();
}

class _SyncPairEditorDialogState extends State<SyncPairEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _leftPath;
  late final TextEditingController _rightPath;
  Bookmark? _leftServer;
  Bookmark? _rightServer;
  late SyncDirection _direction;
  late DeletionPolicy _deletions;
  late BackupPolicy _backups;
  late ComparisonMode _comparison;
  late ConflictDefault _conflictDefault;
  late bool _includeHidden;
  late bool _preserveMtime;
  late final TextEditingController _excludes;
  late final TextEditingController _trashLeft;
  late final TextEditingController _trashRight;
  late final FocusNode _trashLeftFocus;
  late final FocusNode _trashRightFocus;
  late final ExpansibleController _options;
  late final TextEditingController _mtimeTolerance;
  late final TextEditingController _maxDelete;
  late final FocusNode _maxDeleteFocus;
  late final TextEditingController _fractionWarn;
  late int _concurrency;
  bool? _caseLeft;
  bool? _caseRight;

  @override
  void initState() {
    super.initState();
    final pair = widget.initial;
    final rules = pair?.rules ?? const SyncRuleSet();
    _name = TextEditingController(text: pair?.name ?? '');
    _leftPath = TextEditingController(text: _endpointPath(pair?.left));
    _rightPath = TextEditingController(text: _endpointPath(pair?.right));
    _leftServer = _serverMatching(pair?.left);
    _rightServer = _serverMatching(pair?.right);
    _direction = rules.direction;
    _deletions = rules.deletions;
    _backups = rules.backups;
    _comparison = rules.comparison;
    _conflictDefault = rules.conflictDefault;
    _includeHidden = rules.includeHidden;
    _preserveMtime = rules.preserveMtime;
    _excludes = TextEditingController(text: rules.excludeGlobs.join('\n'));
    _trashLeft = TextEditingController(text: rules.trashPathLeft ?? '');
    _trashRight = TextEditingController(text: rules.trashPathRight ?? '');
    _trashLeftFocus = FocusNode(debugLabel: 'sync.trashPath.left');
    _trashRightFocus = FocusNode(debugLabel: 'sync.trashPath.right');
    _options = ExpansibleController();
    _mtimeTolerance = TextEditingController(
      text: '${rules.mtimeToleranceSecs}',
    );
    _maxDelete = TextEditingController(text: '${rules.maxDelete}');
    _maxDeleteFocus = FocusNode(debugLabel: 'sync.maxDelete');
    _fractionWarn = TextEditingController(
      text: '${rules.deleteFractionWarn}',
    );
    _concurrency = rules.transferConcurrency;
    _caseLeft = widget.initialCaseOverrides?.left;
    _caseRight = widget.initialCaseOverrides?.right;

    final warning = _currentTargetedWarning();
    if (warning != null) {
      _trashField(warning.side).text = warning.suggestedTrashPath;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _options.expand();
        _trashFocus(warning.side).requestFocus();
      });
    } else if (widget.initialEditTarget == SyncRulesEditTarget.maxDelete) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _options.expand();
        _maxDeleteFocus.requestFocus();
      });
    }
  }

  SyncDocrootWarning? _currentTargetedWarning() {
    final requested = widget.initialDocrootWarning;
    if (requested == null) return null;

    for (final warning in _docrootWarnings()) {
      if (warning.side == requested.side) return warning;
    }

    return null;
  }

  String _endpointPath(SyncEndpoint? endpoint) => switch (endpoint) {
    LocalEndpoint(:final path) => path,
    RemoteEndpoint(:final path) => path,
    null => '',
  };

  /// The picker value matching [endpoint]'s server ref — remote
  /// endpoints resolve through the same bookmark rows the sidebar
  /// lists, so an embedded identity maps back to its catalog row.
  Bookmark? _serverMatching(SyncEndpoint? endpoint) {
    if (endpoint is! RemoteEndpoint) return null;
    final ref = endpoint.server;
    for (final bookmark in widget.servers) {
      final candidate = bookmark.server;
      if (candidate == null) continue;
      if (_sameServerReference(candidate, ref)) return bookmark;
    }

    // Ad-hoc remote panes need not have a matching remotePath favorite.
    // Keep their embedded server selectable so a rules edit cannot turn
    // the endpoint into a local path.
    final identity = ref.identity;
    final label = identity == null
        ? ref.serverConfigId!
        : '${identity.username}@${identity.host}'
              '${identity.port == 22 ? '' : ':${identity.port}'}';
    return Bookmark(
      id: _unlistedServerId,
      kind: BookmarkKind.remotePath,
      label: label,
      server: ref,
      remotePath: endpoint.path,
      sortKey: '',
      createdAt: _unlistedServerTimestamp,
      updatedAt: _unlistedServerTimestamp,
    );
  }

  List<Bookmark> _serverChoices(Bookmark? selected) {
    if (selected == null || widget.servers.contains(selected)) {
      return widget.servers;
    }

    return [...widget.servers, selected];
  }

  @override
  void dispose() {
    for (final field in [
      _name,
      _leftPath,
      _rightPath,
      _excludes,
      _trashLeft,
      _trashRight,
      _mtimeTolerance,
      _maxDelete,
      _fractionWarn,
    ]) {
      field.dispose();
    }
    _trashLeftFocus.dispose();
    _trashRightFocus.dispose();
    _maxDeleteFocus.dispose();
    _options.dispose();
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _leftPath.text.trim().isNotEmpty &&
      _rightPath.text.trim().isNotEmpty;

  SyncEndpoint _endpointFor(Bookmark? server, TextEditingController path) =>
      server == null
          ? LocalEndpoint(path.text.trim())
          : RemoteEndpoint(server: server.server!, path: path.text.trim());

  TextEditingController _trashField(SyncSide side) =>
      side == SyncSide.left ? _trashLeft : _trashRight;

  FocusNode _trashFocus(SyncSide side) =>
      side == SyncSide.left ? _trashLeftFocus : _trashRightFocus;

  SyncPair _warningPair() {
    final deletions = _direction == SyncDirection.bidirectional
        ? DeletionPolicy.none
        : _deletions;
    return SyncPair(
      id: widget.initial?.id ?? '',
      name: _name.text,
      left: _endpointFor(_leftServer, _leftPath),
      right: _endpointFor(_rightServer, _rightPath),
      rules: SyncRuleSet(
        direction: _direction,
        deletions: deletions,
        backups: _backups,
        trashPathLeft: _optionalText(_trashLeft),
        trashPathRight: _optionalText(_trashRight),
      ),
    );
  }

  List<SyncDocrootWarning> _docrootWarnings() {
    final pair = _warningPair();
    final initial = widget.initial;
    if (initial == null || widget.initialDocrootPaths.isEmpty) {
      return syncDocrootWarnings(pair);
    }

    final resolvedPaths = <SyncSide, SyncDocrootPathState>{};
    for (final entry in widget.initialDocrootPaths.entries) {
      final side = entry.key;
      final endpoint = side == SyncSide.left ? pair.left : pair.right;
      final initialEndpoint = side == SyncSide.left
          ? initial.left
          : initial.right;
      if (canonicalEndpointIdentity(endpoint) !=
          canonicalEndpointIdentity(initialEndpoint)) {
        continue;
      }

      final configured = side == SyncSide.left
          ? pair.rules.trashPathLeft
          : pair.rules.trashPathRight;
      final initialConfigured = side == SyncSide.left
          ? initial.rules.trashPathLeft
          : initial.rules.trashPathRight;
      final resolved = entry.value;
      // Keep canonical roots for aliases; edited trash needs a fresh scan.
      resolvedPaths[side] = SyncDocrootPathState(
        rootPath: resolved.rootPath,
        trashPath: configured == initialConfigured ? resolved.trashPath : null,
        pathStyle: resolved.pathStyle,
        pathCase: resolved.pathCase,
      );
    }

    return syncDocrootWarnings(pair, resolvedPaths: resolvedPaths);
  }

  void _useSuggestedTrashPath(SyncDocrootWarning warning) {
    _trashField(warning.side).text = warning.suggestedTrashPath;
    setState(() {});
    _options.expand();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _trashFocus(warning.side).requestFocus();
    });
  }

  SyncPairEditorResult _result() {
    final initial = widget.initial;
    final deletions = _direction == SyncDirection.bidirectional
        ? DeletionPolicy.none
        : _deletions;
    final left = _endpointFor(_leftServer, _leftPath);
    final right = _endpointFor(_rightServer, _rightPath);
    // copyWith over the edited set: the fields this dialog does not
    // show (acceptedTimeShifts, symlinks) survive the save instead of
    // reverting to their defaults.
    final rules = (initial?.rules ?? const SyncRuleSet()).copyWith(
      direction: _direction,
      deletions: deletions,
      backups: _backups,
      comparison: _comparison,
      mtimeToleranceSecs: int.tryParse(_mtimeTolerance.text.trim()) ?? 2,
      conflictDefault: _conflictDefault,
      excludeGlobs: [
        for (final line in _excludes.text.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ],
      includeHidden: _includeHidden,
      trashPathLeft: () => _optionalText(_trashLeft),
      trashPathRight: () => _optionalText(_trashRight),
      maxDelete: int.tryParse(_maxDelete.text.trim()) ?? 500,
      deleteFractionWarn: double.tryParse(_fractionWarn.text.trim()) ?? 0.5,
      preserveMtime: _preserveMtime,
      transferConcurrency: _concurrency,
    );
    return SyncPairEditorResult(
      pair: SyncPair(
        id: initial?.id ?? uuidV4(),
        name: _name.text.trim(),
        left: left,
        right: right,
        lastRunAt: initial?.lastRunAt,
        rules: rules,
      ),
      caseOverrides: _caseOverridesResult(left, right),
    );
  }

  String? _optionalText(TextEditingController field) {
    final text = field.text.trim();
    return text.isEmpty ? null : text;
  }

  /// The case answers to write, or null to leave the stored pair state
  /// authoritative. Untouched fields over unchanged endpoints return
  /// null — a save that edited only the excludes must not reset an
  /// override the dialog could not see (its seed may be unknown). A
  /// changed endpoint writes what the dialog shows, since the stored
  /// state belongs to the old pair id.
  SyncCaseOverrides? _caseOverridesResult(
    SyncEndpoint left,
    SyncEndpoint right,
  ) {
    final seed = widget.initialCaseOverrides;
    final initial = widget.initial;
    final touched = _caseLeft != seed?.left || _caseRight != seed?.right;
    final moved =
        initial == null ||
        canonicalEndpointIdentity(left) !=
            canonicalEndpointIdentity(initial.left) ||
        canonicalEndpointIdentity(right) !=
            canonicalEndpointIdentity(initial.right);
    if (!touched && !moved) return null;
    return SyncCaseOverrides(left: _caseLeft, right: _caseRight);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final docrootWarnings = _docrootWarnings();
    return AlertDialog(
      title: Text(l10n.syncEditorTitle),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.initial == null,
              decoration: InputDecoration(labelText: l10n.syncEditorNameLabel),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            _EndpointField(
              label: l10n.syncSideLeft,
              servers: _serverChoices(_leftServer),
              localLabel: l10n.syncPairLocalLabel,
              server: _leftServer,
              path: _leftPath,
              onServerChanged: (server) =>
                  setState(() => _leftServer = server),
              onPathChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            _EndpointField(
              label: l10n.syncSideRight,
              servers: _serverChoices(_rightServer),
              localLabel: l10n.syncPairLocalLabel,
              server: _rightServer,
              path: _rightPath,
              onServerChanged: (server) =>
                  setState(() => _rightServer = server),
              onPathChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Dropdown<SyncDirection>(
                    label: l10n.syncModeLabel,
                    value: _direction,
                    items: [
                      (SyncDirection.leftToRight, l10n.syncDirectionLeftToRight),
                      (SyncDirection.rightToLeft, l10n.syncDirectionRightToLeft),
                      (SyncDirection.bidirectional, l10n.syncDirectionBothWays),
                    ],
                    onChanged: (value) => setState(() {
                      _direction = value;
                      // The ruleset's invariant is structural, not a
                      // preference — a bidirectional pick collapses the
                      // deletion policy, never keeps a dead value.
                      if (value == SyncDirection.bidirectional) {
                        _deletions = DeletionPolicy.none;
                      } else if (_deletions == DeletionPolicy.none &&
                          widget.initial?.rules.direction !=
                              SyncDirection.bidirectional) {
                        _deletions = widget.initial?.rules.deletions ??
                            DeletionPolicy.trash;
                      }
                    }),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Dropdown<DeletionPolicy>(
                    label: l10n.syncEditorDeletionsLabel,
                    value: _deletions,
                    enabled: _direction != SyncDirection.bidirectional,
                    items: [
                      (DeletionPolicy.none, l10n.syncEditorDeletionsNone),
                      (DeletionPolicy.trash, l10n.syncEditorDeletionsTrash),
                      (
                        DeletionPolicy.permanent,
                        l10n.syncEditorDeletionsPermanent,
                      ),
                    ],
                    onChanged: (value) => setState(() => _deletions = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final warning in docrootWarnings) ...[
              _DocrootWarning(
                warning: warning,
                l10n: l10n,
                onUseSuggestion: () => _useSuggestedTrashPath(warning),
              ),
              const SizedBox(height: 8),
            ],
            ExpansionTile(
              controller: _options,
              initiallyExpanded: widget.initialDocrootWarning != null,
              title: Text(
                l10n.syncEditorOptionsSection,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _Dropdown<BackupPolicy>(
                        label: l10n.syncEditorBackupsLabel,
                        value: _backups,
                        items: [
                          (BackupPolicy.trash, l10n.syncEditorBackupsTrash),
                          (BackupPolicy.none, l10n.syncEditorBackupsNone),
                        ],
                        onChanged: (value) =>
                            setState(() => _backups = value),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Dropdown<ComparisonMode>(
                        label: l10n.syncEditorComparisonLabel,
                        value: _comparison,
                        items: [
                          (
                            ComparisonMode.sizeAndMtime,
                            l10n.syncEditorComparisonSizeMtime,
                          ),
                          (
                            ComparisonMode.sizeOnly,
                            l10n.syncEditorComparisonSizeOnly,
                          ),
                          (
                            ComparisonMode.contentHash,
                            l10n.syncEditorComparisonContentHash,
                          ),
                        ],
                        onChanged: (value) =>
                            setState(() => _comparison = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _Dropdown<ConflictDefault>(
                  label: l10n.syncEditorConflictLabel,
                  value: _conflictDefault,
                  items: [
                    (ConflictDefault.ask, l10n.syncEditorConflictAsk),
                    (
                      ConflictDefault.newerWins,
                      l10n.syncEditorConflictNewerWins,
                    ),
                    (
                      ConflictDefault.keepLeft,
                      l10n.syncEditorConflictKeepLeft,
                    ),
                    (
                      ConflictDefault.keepRight,
                      l10n.syncEditorConflictKeepRight,
                    ),
                    (ConflictDefault.skip, l10n.syncEditorConflictSkip),
                  ],
                  onChanged: (value) =>
                      setState(() => _conflictDefault = value),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _excludes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: l10n.syncEditorExcludeLabel,
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('sync.trashPath.left'),
                        controller: _trashLeft,
                        focusNode: _trashLeftFocus,
                        decoration: InputDecoration(
                          labelText: l10n.syncEditorTrashLeftLabel,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('sync.trashPath.right'),
                        controller: _trashRight,
                        focusNode: _trashRightFocus,
                        decoration: InputDecoration(
                          labelText: l10n.syncEditorTrashRightLabel,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _IntField(
                        controller: _mtimeTolerance,
                        label: l10n.syncEditorMtimeToleranceLabel,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _IntField(
                        key: const ValueKey('sync.maxDelete'),
                        controller: _maxDelete,
                        focusNode: _maxDeleteFocus,
                        label: l10n.syncEditorMaxDeleteLabel,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _fractionWarn,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]'),
                          ),
                        ],
                        decoration: InputDecoration(
                          labelText: l10n.syncEditorFractionWarnLabel,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _Dropdown<int>(
                  label: l10n.syncEditorConcurrencyLabel,
                  value: _concurrency,
                  items: [
                    for (var i = 1; i <= 8; i++) (i, '$i'),
                  ],
                  onChanged: (value) => setState(() => _concurrency = value),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _CaseOverrideField(
                        label: l10n.syncEditorCaseLeftLabel,
                        value: _caseLeft,
                        l10n: l10n,
                        onChanged: (value) =>
                            setState(() => _caseLeft = value),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _CaseOverrideField(
                        label: l10n.syncEditorCaseRightLabel,
                        value: _caseRight,
                        l10n: l10n,
                        onChanged: (value) =>
                            setState(() => _caseRight = value),
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.syncEditorIncludeHidden),
                  value: _includeHidden,
                  onChanged: (value) =>
                      setState(() => _includeHidden = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.syncEditorPreserveMtime),
                  value: _preserveMtime,
                  onChanged: (value) =>
                      setState(() => _preserveMtime = value),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.syncCancel),
        ),
        FilledButton(
          onPressed: _valid
              ? () => Navigator.of(context).pop(_result())
              : null,
          child: Text(widget.saveLabel ?? l10n.syncEditorSave),
        ),
      ],
    );
  }
}

final class _DocrootWarning extends StatelessWidget {
  const _DocrootWarning({
    required this.warning,
    required this.l10n,
    required this.onUseSuggestion,
  });

  final SyncDocrootWarning warning;
  final AppLocalizations l10n;
  final VoidCallback onUseSuggestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final side = warning.side == SyncSide.left
        ? l10n.syncSideLeft
        : l10n.syncSideRight;
    final body = l10n.syncDocrootWarningBody(
      side,
      isolatePathForDisplay(warning.rootPath),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      label: body,
      child: Material(
        key: ValueKey('sync.docrootWarning.${warning.side.name}'),
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.public_off_outlined,
                      size: 20,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.syncDocrootWarningTitle,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                          Text(
                            body,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Semantics(
                label: l10n.syncDocrootWarningUseSaferPathForSide(side),
                button: true,
                excludeSemantics: true,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: ValueKey(
                      'sync.docrootWarningAction.${warning.side.name}',
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.onErrorContainer,
                    ),
                    onPressed: onUseSuggestion,
                    child: Text(l10n.syncDocrootWarningUseSaferPath),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One endpoint row: the local/server picker and the path field.
class _EndpointField extends StatelessWidget {
  const _EndpointField({
    required this.label,
    required this.servers,
    required this.localLabel,
    required this.server,
    required this.path,
    required this.onServerChanged,
    required this.onPathChanged,
  });

  final String label;
  final List<Bookmark> servers;
  final String localLabel;
  final Bookmark? server;
  final TextEditingController path;
  final ValueChanged<Bookmark?> onServerChanged;
  final ValueChanged<String> onPathChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 160,
          child: DropdownButtonFormField<Bookmark?>(
            initialValue: server,
            isExpanded: true,
            decoration: InputDecoration(labelText: label, isDense: true),
            items: [
              DropdownMenuItem(value: null, child: Text(localLabel)),
              for (final bookmark in servers)
                DropdownMenuItem(
                  value: bookmark,
                  child: Text(
                    bookmark.label,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: onServerChanged,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: path,
            decoration: InputDecoration(
              hintText: AppLocalizations.of(context).syncEditorPathHint,
              isDense: true,
            ),
            onChanged: onPathChanged,
          ),
        ),
      ],
    );
  }
}

/// The per-side case-sensitivity override (05 §3): auto / sensitive /
/// insensitive — the remote side's only sensitivity input.
class _CaseOverrideField extends StatelessWidget {
  const _CaseOverrideField({
    required this.label,
    required this.value,
    required this.l10n,
    required this.onChanged,
  });

  final String label;
  final bool? value;
  final AppLocalizations l10n;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<bool?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: [
        DropdownMenuItem(value: null, child: Text(l10n.syncEditorCaseAuto)),
        DropdownMenuItem(
          value: true,
          child: Text(l10n.syncEditorCaseSensitive),
        ),
        DropdownMenuItem(
          value: false,
          child: Text(l10n.syncEditorCaseInsensitive),
        ),
      ],
      onChanged: onChanged,
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: [
        for (final (item, label) in items)
          DropdownMenuItem(
            value: item,
            child: Text(label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled ? (value) => onChanged(value as T) : null,
    );
  }
}

class _IntField extends StatelessWidget {
  const _IntField({
    super.key,
    required this.controller,
    required this.label,
    this.focusNode,
  });

  final TextEditingController controller;
  final String label;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, isDense: true),
    );
  }
}

bool _sameServerReference(BookmarkServerRef first, BookmarkServerRef second) {
  final firstConfigId = first.serverConfigId;
  final secondConfigId = second.serverConfigId;
  if (firstConfigId != null || secondConfigId != null) {
    return firstConfigId == secondConfigId;
  }

  final firstIdentity = first.identity!;
  final secondIdentity = second.identity!;
  return firstIdentity.host == secondIdentity.host &&
      firstIdentity.port == secondIdentity.port &&
      firstIdentity.username == secondIdentity.username &&
      firstIdentity.authMethod == secondIdentity.authMethod &&
      firstIdentity.secretRef == secondIdentity.secretRef &&
      firstIdentity.identityFilePath == secondIdentity.identityFilePath;
}
