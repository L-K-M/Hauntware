/// The server editor's form (docs/design/ghost-servers-part2.md, F5a-2a),
/// moved from Poltergeist's `lib/ui/server_editor.dart`, which keeps its
/// adapter. A host hands it a [GhostServerEditorDelegate], neutral drafts,
/// its words and faces, and sections of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_marks/ghost_marks.dart';
import 'package:ghost_marks/ghost_marks.dart'
    as marks
    show
        ServerAppearanceStrings,
        ServerMarkImageReader,
        showServerColorPicker,
        showServerMarkPicker;
import 'package:ghost_ui/ghost_ui.dart' show showTopToastIn;
import 'package:seance_protocol/seance_protocol.dart';

import '../../server_config_draft.dart'
    show authMethodOfGhost, ghostAuthMethodOf;
import '../connection_test_report.dart';
import 'delegate.dart';
import 'draft.dart';
import 'strings.dart';

/// Add or edit a server: the form over [delegate], on [existing] or a new
/// server when null, in a dialog at most 520 wide. [monoStyle] draws the
/// pasted key, the login script and the test transcript; [hexStyle] the
/// custom colour picker's hex field. [sections] are drawn after the login
/// script. [readMarkImage] reads the image a mark is imported from, the
/// app's own picker (ghost_marks holds none).
Future<void> showGhostServerEditor(
  BuildContext context,
  GhostServerEditorDelegate delegate,
  GhostServerDraft? existing, {
  GhostServerEditorStrings strings = const GhostServerEditorStrings(),
  marks.ServerAppearanceStrings appearanceStrings =
      const marks.ServerAppearanceStrings(),
  required TextStyle monoStyle,
  required marks.ServerMarkImageReader readMarkImage,
  TextStyle? hexStyle,
  Set<GhostServerOptionalField> fields = const {
    GhostServerOptionalField.startDirectory,
  },
  List<GhostServerEditorSection> sections = const [],
  void Function(Object error, StackTrace stackTrace)? onCopyError,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: _ServerEditor(
          delegate: delegate,
          existing: existing,
          strings: strings,
          appearanceStrings: appearanceStrings,
          monoStyle: monoStyle,
          readMarkImage: readMarkImage,
          hexStyle: hexStyle,
          fields: fields,
          sections: sections,
          onCopyError: onCopyError,
        ),
      ),
    ),
  );
}

/// The dialog [ghostExcludingNeedsConfirmation] gates, as a function so a
/// test can tap its buttons without standing up an editor.
///
/// Dismissing it — barrier tap, Escape — resolves to null, which has to read
/// as "no": the caller is about to delete data on other devices, and the one
/// input that means the user never answered must not be the one that proceeds.
Future<bool> showGhostSyncExclusionConfirmation(
  BuildContext context, {
  GhostServerEditorStrings strings = const GhostServerEditorStrings(),
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(strings.excludeConfirmTitle),
      content: Text(strings.excludeConfirmBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(strings.excludeConfirmCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(strings.excludeConfirmAction),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// The editor's form, over [GhostServerEditorDelegate] and neutral drafts so
/// it can move into ghost_servers unchanged (docs/design/
/// ghost-servers-part2.md, F5a-2a).
class _ServerEditor extends StatefulWidget {
  final GhostServerEditorDelegate delegate;
  final GhostServerDraft? existing;
  final GhostServerEditorStrings strings;
  final marks.ServerAppearanceStrings appearanceStrings;
  final TextStyle monoStyle;
  final marks.ServerMarkImageReader readMarkImage;
  final TextStyle? hexStyle;
  final Set<GhostServerOptionalField> fields;
  final List<GhostServerEditorSection> sections;
  final void Function(Object error, StackTrace stackTrace)? onCopyError;
  const _ServerEditor({
    required this.delegate,
    this.existing,
    required this.strings,
    required this.appearanceStrings,
    required this.monoStyle,
    required this.readMarkImage,
    this.hexStyle,
    required this.fields,
    this.sections = const [],
    this.onCopyError,
  });

  @override
  State<_ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<_ServerEditor> {
  GhostServerEditorStrings get _strings => widget.strings;

  final _form = GlobalKey<FormState>();
  late final TextEditingController _label;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _group;
  final _password = TextEditingController();
  final _keyPem = TextEditingController();
  final _keyPath = TextEditingController();
  final _keyPassphrase = TextEditingController();
  final _loginScript = TextEditingController();
  final _startDirectory = TextEditingController();

  late AuthMethod _auth;
  late ServerTint _tint;

  /// What a server shows before anything is chosen. Named once: the reset
  /// button's visibility and its action both compare against it, and a second
  /// literal that drifted would leave the button offering to reset a mark that
  /// is already default.
  static const ServerMark _defaultMark = ServerGlyphMark(null);

  /// What the badge shows: a glyph, an emoji, or an imported image. Held as
  /// the resolved mark rather than as the three fields it is stored in, so
  /// the precedence between them lives in one place (see [ServerMark]).
  late ServerMark _mark;
  bool _referenceKeyFile = true;
  late bool _syncSecret;
  late bool _excludeFromSync;
  bool _busy = false;

  /// The id a *new* server will be saved under, minted once rather than per
  /// save so a test connection and the save that follows describe one server,
  /// and so a save that failed and is retried does not mint a second identity.
  late final String _draftId;

  /// The vault id a *new* server's credential is saved under, minted once for
  /// the same reason as [_draftId] and one the credential needs more:
  /// `save` writes the vault before the config store, so a save that
  /// stored the secret and then failed on the config write left an entry
  /// behind — and a retry minting a fresh id orphaned it in the keyring with
  /// nothing pointing at it and nothing that would ever clean it up.
  late final String _draftSecretId;

  /// The connection test: whether one is running, what the last one found,
  /// and which attempt is current. The counter is the cancellation flag — the
  /// SSH layer has no cancel seam, so a superseded or abandoned attempt is
  /// left to finish and its result dropped.
  bool _testing = false;
  GhostTestReport? _testResult;
  int _testAttempt = 0;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _draftId = widget.delegate.newId();
    _draftSecretId = widget.delegate.newId();
    _label = TextEditingController(text: e?.label ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? 22}');
    _user = TextEditingController(text: e?.username ?? '');
    _group = TextEditingController(text: e?.group ?? '');
    // As `ServerTint.of` and `ServerConfig.mark` read the stored fields.
    _tint = e == null
        ? ServerTint.none
        : ServerTint(
            named: ServerColor.values.asNameMap()[e.colorName],
            custom: parseServerCustomColor(e.customColor),
          );
    _mark = e == null
        ? _defaultMark
        : ServerMark.resolve(
            icon: ServerIcon.values.asNameMap()[e.iconName],
            emoji: e.iconEmoji,
            image: e.iconImage,
          );
    _auth = e == null ? AuthMethod.agent : authMethodOfGhost(e.authMethod);
    _keyPath.text = e?.identityFilePath ?? '';
    _referenceKeyFile = e?.identityFilePath != null;
    _loginScript.text = e?.loginScript ?? '';
    _startDirectory.text = e?.startDirectory ?? '';
    // New credentials default to syncable (a no-op until the global "sync
    // saved passwords & keys" is on); existing servers keep their stored
    // choice.
    _syncSecret = e?.syncSecret ?? true;
    _excludeFromSync = e?.excludeFromSync ?? false;
    for (final field in _connectionFields) {
      field.addListener(_dropTestResult);
    }
  }

  /// Every text field in the form, so [dispose] releases them all.
  List<TextEditingController> get _fields => [
    _label,
    _host,
    _port,
    _user,
    _group,
    _password,
    _keyPem,
    _keyPath,
    _keyPassphrase,
    _loginScript,
    _startDirectory,
  ];

  /// The fields a connection test's outcome actually depends on.
  ///
  /// Narrower than [_fields] because [_dropTestResult] does not merely grey
  /// out a stale result — it bumps `_testAttempt`, which abandons a test
  /// still in flight. Renaming a server, moving it to another group or
  /// editing its login script cannot change what a connection does (the
  /// script is never executed, which the disclaimer beside it says), so
  /// discarding a result the user waited minutes for over a typo in the name
  /// is a cost with nothing bought for it.
  List<TextEditingController> get _connectionFields => [
    _host,
    _port,
    _user,
    _password,
    _keyPem,
    _keyPath,
    _keyPassphrase,
  ];

  /// Forget the last test result, and abandon one still running, because the
  /// form no longer describes what is being tested.
  ///
  /// A green "authenticated" sitting beside a host that has since been retyped
  /// reads as current, and the report's whole claim is that it describes the
  /// server about to be saved. An attempt *in flight* is the same problem
  /// arriving late, so the counter moves too and its result lands as
  /// superseded — which means clearing [_testing] here as well, or the *Test*
  /// button would stay disabled behind a live spinner, waiting on a result
  /// that will be dropped. Save is never gated on a running test: it takes
  /// `_busy` alone, so a test in flight does not block saving.
  ///
  /// Guarded so typing does not rebuild the dialog on every keystroke.
  void _dropTestResult() {
    _testAttempt++;
    if (_testResult != null || _testing) {
      setState(() {
        _testResult = null;
        _testing = false;
      });
    }
  }

  @override
  void dispose() {
    for (final c in _fields) {
      // Disposing drops the listeners with it; removing them first is only so
      // a late notification cannot reach setState on the way down.
      c.removeListener(_dropTestResult);
      c.dispose();
    }
    super.dispose();
  }

  /// Whether Return, pressed with the focus where it is now, should save.
  ///
  /// Save is the dialog's default button, and a form whose fields swallow
  /// Return is one where the mouse has to come back at the end of every
  /// edit. But Return already means something in two places: a multi-line
  /// field, where it is a newline, and a focused control that activates on
  /// it — a button, a switch, the auth dropdown — where the app-level binding
  /// would otherwise fire it. Both keep their meaning; everywhere else it is
  /// Save. Answered false rather than swallowing the key, so the event goes
  /// on to whatever owned it before this existed. [anywhere] is the modified
  /// chord, which saves even from the script box.
  ///
  /// Gated on [_busy] alone, like the Save button: a connection test in
  /// flight does not block saving (see the button for why), so Return does
  /// not either.
  ///
  /// An input method mid-composition is the third owner of Return. The
  /// desktop engines hand a key to the framework first and to the input
  /// method only if the framework declined, so while a Japanese or Chinese
  /// composition is open the key has to be declined here for Return to
  /// commit the text rather than save around it.
  bool _returnSaves({required bool anywhere}) {
    if (_busy) return false;
    final focus = FocusManager.instance.primaryFocus?.context;
    final editable = focus?.findAncestorWidgetOfExactType<EditableText>();
    // Before the chord's early return: a composition is open text, and the
    // chord saving around it would persist the half-typed preedit.
    if (editable != null) {
      final composing = editable.controller.value.composing;
      if (composing.isValid && !composing.isCollapsed) return false;
    }
    if (anywhere) return true;
    if (focus == null) return true;
    if (editable != null && editable.maxLines != 1) return false;
    return Actions.maybeFind<ActivateIntent>(focus) == null;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): _SaveIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): _SaveIntent(),
        // The chord editors use for "submit despite being multi-line", on
        // both modifier conventions, since the shortcut is unbound otherwise
        // and a macOS user's hands expect the one, a Linux user's the other.
        SingleActivator(LogicalKeyboardKey.enter, control: true): _SaveIntent(
          anywhere: true,
        ),
        SingleActivator(LogicalKeyboardKey.enter, meta: true): _SaveIntent(
          anywhere: true,
        ),
        SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
            _SaveIntent(anywhere: true),
        SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true):
            _SaveIntent(anywhere: true),
      },
      child: Actions(
        actions: {_SaveIntent: _SaveAction(this)},
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null ? _strings.addTitle : _strings.editTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _label,
              decoration: InputDecoration(labelText: _strings.label),
              validator: _required,
            ),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _host,
                    decoration: InputDecoration(labelText: _strings.host),
                    validator: _required,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    decoration: InputDecoration(labelText: _strings.port),
                    keyboardType: TextInputType.number,
                    validator: _validatePort,
                  ),
                ),
              ],
            ),
            TextFormField(
              controller: _user,
              decoration: InputDecoration(labelText: _strings.username),
              validator: _required,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<AuthMethod>(
              initialValue: _auth,
              decoration: InputDecoration(labelText: _strings.authentication),
              items: [
                DropdownMenuItem(
                  value: AuthMethod.agent,
                  child: Text(_strings.authAgent),
                ),
                DropdownMenuItem(
                  value: AuthMethod.password,
                  child: Text(_strings.authPassword),
                ),
                DropdownMenuItem(
                  value: AuthMethod.privateKey,
                  child: Text(_strings.authPrivateKey),
                ),
              ],
              // Through _dropTestResult, not a bare clear: the auth method is
              // baked into the config a test runs against, so one already in
              // flight is describing a credential the form no longer holds —
              // and would otherwise land looking current.
              onChanged: (v) {
                setState(() => _auth = v ?? AuthMethod.agent);
                _dropTestResult();
              },
            ),
            const SizedBox(height: 8),
            ..._authFields(),
            const SizedBox(height: 20),
            ..._syncFields(),
            const SizedBox(height: 20),
            if (widget.fields.contains(
              GhostServerOptionalField.startDirectory,
            )) ...[
              ..._startDirectoryFields(),
              const SizedBox(height: 20),
            ],
            ..._loginScriptFields(),
            const SizedBox(height: 20),
            for (final section in widget.sections) ...[
              section.build(context),
              const SizedBox(height: 20),
            ],
            ..._appearanceFields(),
            const SizedBox(height: 20),
            Row(
              children: [
                // Flexible, so the row never overflows: on a phone at a large
                // text scale the three buttons are wider than the dialog, and
                // this is the one whose label can wrap onto a second line
                // without changing what the row means.
                Flexible(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      onPressed: _busy || _testing ? null : _testConnection,
                      icon: _testing
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              // Labelled like the outcome icons: a spinner is
                              // the one state with nothing to read, so without
                              // this a screen-reader user cannot tell a running
                              // test from a button that did nothing.
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                semanticsLabel: _strings.testingSemantic,
                              ),
                            )
                          : const Icon(Icons.wifi_tethering, size: 18),
                      label: Text(_testing ? _strings.testing : _strings.test),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Cancel stays live during a test: the attempt cannot be
                // stopped, but being unable to leave the dialog for the five
                // minutes an authentication may take is worse than letting it
                // finish unwatched.
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(_strings.cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  // Not disabled while a test runs: an attempt can take
                  // minutes, and the only other way out was typing a character
                  // into any field to drop the test. Saving mid-test is sound
                  // — any edit that could make the two disagree already
                  // supersedes the attempt, and the save pops the editor, so
                  // the late result is discarded by the mounted check.
                  onPressed: _busy ? null : _save,
                  child: Text(_strings.save),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _strings.testDisclaimer,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
            if (_testResult != null) const SizedBox(height: 12),
            // The spinner announces that a test started; without this the one
            // thing that matters — how it ended — arrives silently, and a
            // screen-reader user has to go looking for it. Kept mounted while
            // idle rather than added with the result: several screen readers
            // announce a live region whose content changes and stay quiet for
            // one that appears already filled.
            Semantics(
              liveRegion: true,
              child: _testResult == null
                  ? const SizedBox.shrink()
                  : GhostConnectionTestReport(
                      report: _testResult!,
                      monoStyle: widget.monoStyle,
                      strings: _strings.testStrings,
                      logStrings: _strings.logStrings,
                      onCopyError: widget.onCopyError,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _authFields() {
    switch (_auth) {
      case AuthMethod.agent:
        return [Text(_strings.agentInfo)];
      case AuthMethod.password:
        return [
          TextFormField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(labelText: _strings.passwordLabel),
          ),
          _syncSecretToggle(),
        ];
      case AuthMethod.privateKey:
        return [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_strings.referenceKeyTitle),
            subtitle: Text(_strings.referenceKeySubtitle),
            value: _referenceKeyFile,
            // Same as the auth dropdown: this switches the test between the
            // key on disk and the pasted one, so an attempt already running
            // is about the other of the two.
            onChanged: (v) {
              setState(() => _referenceKeyFile = v);
              _dropTestResult();
            },
          ),
          if (_referenceKeyFile)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _keyPath,
                    decoration: InputDecoration(
                      labelText: _strings.identityFilePath,
                      hintText: _strings.identityFileHint,
                    ),
                  ),
                ),
                if (widget.delegate.canPickIdentityFile) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : _browseForKey,
                    child: Text(_strings.browse),
                  ),
                ],
              ],
            )
          else
            TextFormField(
              controller: _keyPem,
              maxLines: 5,
              style: widget.monoStyle.copyWith(fontSize: 12),
              decoration: InputDecoration(
                labelText: _strings.privateKeyPem,
                border: const OutlineInputBorder(),
              ),
            ),
          TextFormField(
            controller: _keyPassphrase,
            obscureText: true,
            decoration: InputDecoration(labelText: _strings.keyPassphrase),
          ),
          // Only the stored key (not the referenced-file case) is a secret
          // that could sync.
          if (!_referenceKeyFile) _syncSecretToggle(),
        ];
    }
  }

  /// Where a pane opens when it connects to this server as a whole (a
  /// SERVERS row, not a favorite, which carries its own path). Part of the
  /// synced config, so every device opens the same folder; Séance carries
  /// it without showing it.
  List<Widget> _startDirectoryFields() {
    return [
      const Divider(),
      const SizedBox(height: 8),
      TextFormField(
        key: const ValueKey('serverEditor.startDirectory'),
        controller: _startDirectory,
        decoration: InputDecoration(
          labelText: _strings.startDirectory,
          hintText: _strings.startDirectoryHint,
        ),
        validator: _validateStartDirectory,
      ),
      const SizedBox(height: 4),
      Text(
        _strings.startDirectoryNote,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
      ),
    ];
  }

  /// An optional command to run in this server's shell once it opens. Typed
  /// into the session rather than executed on a side channel — which is what
  /// Séance does with it when the server opens a terminal there; Poltergeist
  /// stores and syncs the field so a round trip preserves it.
  List<Widget> _loginScriptFields() {
    return [
      const Divider(),
      const SizedBox(height: 8),
      TextFormField(
        controller: _loginScript,
        maxLines: 3,
        minLines: 1,
        style: widget.monoStyle.copyWith(fontSize: 12),
        decoration: InputDecoration(
          labelText: _strings.loginScript,
          hintText: _strings.loginScriptHint,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        _strings.loginScriptNote,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
      ),
    ];
  }

  /// How this server is filed and marked in the list: its group, its accent
  /// colour, and its icon. All three are optional and none of them affect how
  /// the connection is made — they exist so a list of thirty boxes can be read
  /// at a glance, and so "am I on prod?" has an answer you don't have to read.
  List<Widget> _appearanceFields() {
    final existing = widget.delegate.serverGroups;
    return [
      const Divider(),
      const SizedBox(height: 8),
      Row(
        children: [
          // Colour and mark combine, so they are previewed together rather
          // than left to be imagined from two separate pickers — and as the
          // list draws them: the colour a line beside the mark, not under it.
          ServerAccentBar(tint: _tint),
          const SizedBox(width: 8),
          ServerBadge(tint: _tint, mark: _mark),
          const SizedBox(width: 12),
          Text(
            _strings.appearance,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _group,
        decoration: InputDecoration(
          labelText: _strings.group,
          hintText: _strings.groupHint,
        ),
      ),
      if (existing.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            // Retyping an existing group by hand is how you end up with
            // "Prod " and "prodution" as separate sections. Case already
            // folds together; the chips take care of the rest.
            for (final group in existing)
              ActionChip(
                label: Text(group),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _group.text = group),
              ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      Text(_strings.colour, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final color in <ServerColor?>[null, ...ServerColor.values])
            _ColorSwatch(
              tint: ServerTint(named: color),
              selected: _tint == ServerTint(named: color),
              onTap: () => setState(() => _tint = ServerTint(named: color)),
            ),
          // Last, after the named ten: the picker is the way past them, not
          // the first thing to reach for.
          _CustomColorSwatch(
            color: _tint.custom,
            onTap: _pickCustomColor,
            strings: _strings,
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text(_strings.mark, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 6),
      // A button rather than the grid this used to be: the glyphs alone no
      // longer fit a form field, and emoji and imported images need room of
      // their own. The preview beside "Appearance" above shows the result.
      // Wrap rather than Row: at 280 logical pixels of form width — what a
      // dialog gives on a phone — and 1.5x text the three controls overflow
      // a Row by 30 pixels. Measured, and the reason the grid this replaced
      // was a Wrap too.
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ServerBadge(tint: _tint, mark: _mark, size: 44),
          OutlinedButton.icon(
            onPressed: _pickMark,
            icon: const Icon(Icons.palette_outlined),
            label: Text(_strings.chooseMark),
          ),
          if (_mark != _defaultMark)
            IconButton(
              tooltip: _strings.defaultMarkTooltip,
              icon: const Icon(Icons.backspace_outlined),
              onPressed: () => setState(() => _mark = _defaultMark),
            ),
        ],
      ),
    ];
  }

  Future<void> _pickMark() async {
    final chosen = await marks.showServerMarkPicker(
      context,
      current: _mark,
      accent: _tint,
      strings: widget.appearanceStrings,
      readImage: widget.readMarkImage,
    );
    if (chosen == null || !mounted) return;
    setState(() => _mark = chosen);
  }

  /// Open the colour picker on the colour in force: the custom one if there
  /// is one, else the seed of the named accent — so "a bit darker than teal"
  /// starts from teal — else the app's own seed.
  Future<void> _pickCustomColor() async {
    final named = _tint.named;
    final chosen = await marks.showServerColorPicker(
      context,
      initial:
          _tint.custom ??
          (named == null ? widget.delegate.themeSeed : serverColorSeed(named)),
      mark: _mark,
      strings: widget.appearanceStrings,
      colorStrings: _strings.colorPickerStrings,
      hexStyle: widget.hexStyle,
    );
    if (chosen == null || !mounted) return;
    setState(() => _tint = ServerTint.custom(chosen));
  }

  /// Per-server opt-in for including this credential in sync. Gated globally
  /// by the "Sync saved passwords & keys" setting, so it's a no-op until
  /// that's on.
  ///
  /// Excluding the whole server settles the question, so the switch reads off
  /// and takes no input then. What it *stores* is still the user's own choice
  /// ([_syncSecret]) rather than the displayed false: clearing the exclusion
  /// has to give them back the answer they picked, not silently opt their
  /// credential out on the way through.
  Widget _syncSecretToggle() {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(_strings.syncSecretTitle),
      subtitle: Text(
        _excludeFromSync
            ? _strings.syncSecretExcluded
            : _strings.syncSecretSubtitle,
      ),
      value: _syncSecret && !_excludeFromSync,
      onChanged: _excludeFromSync
          ? null
          : (v) => setState(() => _syncSecret = v),
    );
  }

  /// Whether this server takes part in sync at all.
  ///
  /// Worth saying out loud in the subtitle, because "exclude" understates what
  /// the switch does to a server that has already synced: the retraction is a
  /// tombstone, so the other devices lose their copy. Only this device keeps
  /// one, which is the point — but it is not something to find out afterwards.
  List<Widget> _syncFields() {
    return [
      const Divider(),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(_strings.excludeTitle),
        subtitle: Text(
          _excludeFromSync
              ? _strings.excludeOnSubtitle
              : _strings.excludeOffSubtitle,
        ),
        value: _excludeFromSync,
        onChanged: (v) async {
          if (v && !await _confirmExclusion()) return;
          if (mounted) setState(() => _excludeFromSync = v);
        },
      ),
    ];
  }

  /// Ask before an exclusion that reaches other devices.
  ///
  /// Turning this on for a server that may already have synced is the one
  /// thing this editor does that deletes data somewhere else, and the switch
  /// sits a few rows from the login script and the colour picker, which lowers
  /// the stakes it looks like it carries. Subtitles get skimmed; a dialog does
  /// not.
  ///
  /// Nothing is asked when there is nothing to retract — a server being added
  /// has never been anywhere, and with no sync account configured there is no
  /// other device to lose it. Turning the switch back off is not destructive
  /// either way.
  Future<bool> _confirmExclusion() =>
      ghostExcludingNeedsConfirmation(
        existing: widget.existing,
        syncConfigured: widget.delegate.syncConfigured,
      )
      ? showGhostSyncExclusionConfirmation(context, strings: _strings)
      : Future<bool>.value(true);

  /// Pick an identity file: "reference, don't store" mode reads the key from
  /// this path at connect time.
  Future<void> _browseForKey() async {
    final picked = await widget.delegate.pickIdentityFile();
    if (picked == null || !mounted) return;
    setState(() => _keyPath.text = picked);
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? _strings.required : null;

  String? _validatePort(String? v) {
    final port = int.tryParse((v ?? '').trim());
    if (port == null || port < 1 || port > 65535) {
      return _strings.portRange;
    }
    return null;
  }

  /// Blank is the home folder; anything else must be a path the protocol
  /// keeps, or the save would silently drop it.
  String? _validateStartDirectory(String? v) {
    final value = v ?? '';
    if (value.trim().isEmpty) return null;
    if (normalizeServerStartDirectory(value) != null) return null;
    return _strings.startDirectoryInvalid;
  }

  /// The server the form currently describes, trimmed and normalized as it
  /// would be stored. Shared by Save and Test connection so a test can never
  /// run against a different server than the one about to be saved.
  GhostServerDraft _formDraft() {
    final existing = widget.existing;
    // Read once rather than per field: encoding an image mark for storage is
    // not free, and the fields have to come from one reading anyway so they
    // cannot disagree about which is in force.
    final mark = _mark.stored;
    final tint = _tint.stored;
    return GhostServerDraft(
      id: existing?.id ?? _draftId,
      label: _label.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      username: _user.text.trim(),
      authMethod: ghostAuthMethodOf(_auth),
      // Blank reads as "no file referenced", not as a path made of nothing:
      // the validator blocks an empty path, and a caller that ever reached
      // here without it would otherwise ask the SSH layer to read `''`.
      identityFilePath:
          (_auth == AuthMethod.privateKey &&
              _referenceKeyFile &&
              _keyPath.text.trim().isNotEmpty)
          ? _keyPath.text.trim()
          : null,
      syncSecret: _syncSecret,
      // Normalized here rather than trusted from the field, so a trailing
      // space typed into the group name can't fork a second section that
      // looks identical to the one the user meant to join.
      group: normalizeServerGroup(_group.text),
      colorName: tint.color?.name,
      customColor: tint.customColor,
      iconName: mark.icon?.name,
      iconEmoji: mark.emoji,
      iconImage: mark.image,
      loginScript: normalizeLoginScript(_loginScript.text),
      // A field the host hides keeps the value it was opened with.
      startDirectory:
          widget.fields.contains(GhostServerOptionalField.startDirectory)
          ? normalizeServerStartDirectory(_startDirectory.text)
          : existing?.startDirectory,
      excludeFromSync: _excludeFromSync,
    );
  }

  /// Connect and authenticate with what the form holds right now — including
  /// a password or key typed but not yet saved, which is not in the vault and
  /// would otherwise be tested as whatever is stored (or as nothing at all,
  /// for a server being added).
  Future<void> _testConnection() async {
    if (!_form.currentState!.validate()) return;
    final attempt = ++_testAttempt;
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final GhostTestReport result;
    try {
      result = await widget.delegate.testConnection(
        _formDraft(),
        // A credential box is hidden (and stale) once the auth method stops
        // using it, and the PEM box also while the key is referenced from
        // disk; passing either then would test text the user cannot see.
        // The passphrase stays with the method, not the reference toggle: it
        // decrypts the on-disk key too.
        GhostCredentialDraft(
          password: _auth == AuthMethod.password ? _password.text : null,
          privateKeyPem: _auth == AuthMethod.privateKey && !_referenceKeyFile
              ? _keyPem.text
              : null,
          keyPassphrase: _auth == AuthMethod.privateKey
              ? _keyPassphrase.text
              : null,
        ),
      );
    } catch (error) {
      // The delegate turns every failure it can see into a report, so
      // reaching here means something outside it went wrong. Belt and braces,
      // because the alternative is the wedged editor `_save` is careful to
      // avoid: _testing stuck on, Save disabled, and Cancel — which throws
      // away everything just typed — as the only way out.
      if (!mounted || attempt != _testAttempt) return;
      setState(() {
        _testing = false;
        _testResult = GhostTestReport(
          ok: false,
          summary: _strings.testFailedSummary,
          notes: ['$error'],
          log: '',
        );
      });
      return;
    }
    // Superseded by a newer attempt, or the dialog is gone: drop it.
    if (!mounted || attempt != _testAttempt) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    // Everything the form says, read here — before anything is awaited.
    // `_busy` disables the buttons, not the fields, so a keyring that prompts
    // (macOS) or is slow to answer leaves them editable for as long as it
    // takes: read afterwards, a keystroke landing in that window is saved
    // without ever passing the `validate()` this method opened with, and a
    // host cleared after Save was pressed is written empty. The auth
    // dropdown and the reference switch too, which the credential is planned
    // from after that wait.
    final save = GhostServerSave(
      draft: _formDraft(),
      credential: GhostCredentialEntry(
        referenceKeyFile: _referenceKeyFile,
        password: _password.text,
        keyPem: _keyPem.text,
        keyPassphrase: _keyPassphrase.text,
      ),
      draftSecretId: _draftSecretId,
    );
    final writes = [
      for (final section in widget.sections) (section, section.capture()),
    ];
    try {
      // Throws when the OS keyring is unavailable or the write fails — tell
      // the user instead of wedging the editor with _busy stuck on.
      await widget.delegate.save(save);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showTopToastIn(context, message: _strings.saveFailed('$e'));
      return;
    }
    // After the server, so one that failed to save never gains a section's
    // setting.
    for (final (section, write) in writes) {
      if (write == null) continue;
      try {
        await write(save.draft.id);
      } catch (e) {
        // The server is saved; the editor stays open so Save retries the
        // part that failed.
        if (!mounted) return;
        setState(() => _busy = false);
        showTopToastIn(context, message: section.failureMessage(e));
        return;
      }
    }
    if (mounted) Navigator.of(context).pop();
  }
}

/// Return, in the editor: save the server, unless the focus is somewhere the
/// key means something else (see `_returnSaves`).
class _SaveIntent extends Intent {
  /// Set for the modified chord, which saves wherever the focus is.
  final bool anywhere;
  const _SaveIntent({this.anywhere = false});
}

/// An [Action] rather than a callback so that declining is possible: an
/// action that is not enabled leaves the key event unhandled, and it carries
/// on to the text field or button that was going to take it. A
/// `CallbackShortcuts` binding would have consumed it either way.
class _SaveAction extends Action<_SaveIntent> {
  final _ServerEditorState _editor;
  _SaveAction(this._editor);

  @override
  bool isEnabled(_SaveIntent intent) =>
      _editor._returnSaves(anywhere: intent.anywhere);

  @override
  Object? invoke(_SaveIntent intent) {
    _editor._save();
    return null;
  }
}

/// One choice in the colour row. The first is null — "no colour" — drawn as
/// the same neutral tone an untagged server gets in the list, so the option
/// shows what it does rather than describing it.
class _ColorSwatch extends StatelessWidget {
  final ServerTint tint;
  final bool selected;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.tint,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = serverAccent(context, tint);
    final fill = accent?.container ?? scheme.surfaceContainerHighest;
    final foreground = accent?.onContainer ?? scheme.onSurfaceVariant;
    // Declared selected, like the mark picker's tiles: the ring and the tick
    // are visual, and a screen reader is otherwise told eleven equal
    // buttons.
    return Semantics(
      button: true,
      selected: selected,
      child: Tooltip(
        message: serverColorLabel(tint.named),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: _swatchSize,
            height: _swatchSize,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? _selectedSwatchBorder : 1,
              ),
            ),
            // A tick rather than a ring alone: at 34px on a phone the ring
            // is easy to miss, and the swatches differ only by hue.
            child: selected
                ? Icon(Icons.check, size: _swatchIconSize, color: foreground)
                : null,
          ),
        ),
      ),
    );
  }
}

/// The colour row's geometry, shared by the named swatches and the custom
/// one so the row reads as one control.
const double _swatchSize = 34;
const double _selectedSwatchBorder = 2.5;
const double _swatchIconSize = 16;

/// The colour row's way past the named ten: a swatch that opens the picker.
///
/// Shows the custom colour when one is chosen, as a swatch like its
/// neighbours, so the row reads "this one is selected" the same way whether
/// the choice was named or picked. With none chosen it wears the spectrum
/// instead of a colour, which is the one honest answer to "what does this
/// button give me" before it has been pressed.
class _CustomColorSwatch extends StatelessWidget {
  /// The custom colour in force, or null when a named accent (or none) is.
  final Color? color;
  final VoidCallback onTap;
  final GhostServerEditorStrings strings;

  const _CustomColorSwatch({
    required this.color,
    required this.onTap,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = color;
    final selected = chosen != null;
    final accent = chosen == null
        ? null
        : serverAccent(context, ServerTint(custom: chosen));
    return Semantics(
      button: true,
      selected: selected,
      child: Tooltip(
        message: chosen == null
            ? strings.customColour
            : strings.customColourValue(formatServerCustomColor(chosen)),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: _swatchSize,
            height: _swatchSize,
            decoration: BoxDecoration(
              color: accent?.container,
              gradient: selected
                  ? null
                  : SweepGradient(
                      colors: [
                        for (var hue = 0; hue <= 360; hue += 60)
                          HSVColor.fromAHSV(
                            1,
                            hue.toDouble(),
                            0.6,
                            0.95,
                          ).toColor(),
                      ],
                    ),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? _selectedSwatchBorder : 1,
              ),
            ),
            child: Icon(
              selected ? Icons.check : Icons.colorize,
              size: _swatchIconSize,
              // Over the spectrum, a fixed dark tone: no single "on" colour
              // fits every hue, and the lighter tones the sweep is drawn in
              // carry dark well enough.
              color: accent?.onContainer ?? Colors.black87,
            ),
          ),
        ),
      ),
    );
  }
}
