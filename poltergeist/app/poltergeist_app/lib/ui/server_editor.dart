// Ported from Séance app/seance_app/lib/ui/server_editor.dart @ 5d578b9; see
// docs/PORTS.md.
// Divergences: `AppState` becomes [ServerEditorDelegate] — the seven seams
// the form actually uses, so the dialog builds in a widget test without
// standing up the app. Strings localize through ARB (D20). The
// security-scoped identity-file bookmark machinery (`_keyBookmark`,
// `_bookmarkFor`, `draftIdentityBookmark`) is dropped: Poltergeist is not
// sandboxed, so Browse… returns a plain path and the referenced key opens
// by path at connect. Poltergeist adds the D37 "Simultaneous transfers"
// override, which Séance has no use for and which is stored on the device
// rather than in the synced config.
// Since F5a-2a the form is ghost_servers' showGhostServerEditor
// (docs/design/ghost-servers-part2.md); this file keeps the app's seam, the
// session adapter over it and the transfer limit section.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:ghost_servers/server_config_draft.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/application_error_reporter.dart';
import '../services/transfer_limits_controller.dart'
    show transferConcurrencyChoices;
import '../services/uuid.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;
import 'ghost_servers_adapter.dart'
    show ghostTestReportOf, poltergeistServerEditorStrings;
import 'server_appearance_strings.dart';

/// What the editor needs from the application layer — the seams Séance's
/// `AppState`/`AppServices` answered, named one per use so a test double is a
/// handful of fields rather than a services hierarchy.
abstract class ServerEditorDelegate {
  /// The catalog's servers, for the group quick-select chips and for the
  /// freshest `updatedAt` a save must outrank.
  List<ServerConfig> get servers;

  /// Whether a sync account is linked — gates the exclusion confirmation.
  bool get syncConfigured;

  /// The app's own seed colour, the custom picker's starting point when no
  /// named accent is in force.
  Color get themeSeed;

  /// Pick a "reference, don't store" identity file; null when cancelled.
  Future<String?> pickIdentityFile();

  /// The stored credential [secretId] names — for the referenced-key
  /// passphrase carry-over. Throws when the vault is locked.
  Future<Secret?> readSecret(String secretId);

  /// Persist the config and, when [secret] is given, its credential. Throws
  /// when the vault is unavailable or the write fails.
  Future<void> save(ServerConfig config, {Secret? secret});

  /// D37: the cap every server follows unless it chose its own — what the
  /// editor's "Default (…)" choice names.
  TransferConcurrency get defaultTransferConcurrency;

  /// [serverId]'s own cap on simultaneous transfers, or null when it
  /// follows [defaultTransferConcurrency].
  TransferConcurrency? transferConcurrencyFor(String serverId);

  /// Store [serverId]'s own cap, or clear it with null. Device-local, not
  /// part of the synced config. Throws when the write fails.
  Future<void> saveTransferConcurrency(
    String serverId,
    TransferConcurrency? value,
  );

  /// Authenticate against the form's draft state — typed-but-unsaved
  /// credential fields included — and report it.
  Future<ConnectionTestResult> testConnection(
    ServerConfig config, {
    String? draftPassword,
    String? draftPrivateKey,
    String? draftKeyPassphrase,
    SshConnectionLog? log,
  });
}

/// Whether turning "exclude from sync" on needs confirming before it takes:
/// ghost_servers' [ghostExcludingNeedsConfirmation], over a stored config.
bool excludingNeedsConfirmation({
  required ServerConfig? existing,
  required bool syncConfigured,
}) => ghostExcludingNeedsConfirmation(
  existing: existing == null ? null : ghostServerDraftOf(existing),
  syncConfigured: syncConfigured,
);

/// The dialog [excludingNeedsConfirmation] gates: ghost_servers'
/// [showGhostSyncExclusionConfirmation] in this app's words.
Future<bool> confirmSyncExclusion(
  BuildContext context,
  GhostServerEditorStrings strings,
) => showGhostSyncExclusionConfirmation(context, strings: strings);

/// Add or edit a server. Password / private-key material is written to the
/// encrypted vault; the config stores only a reference.
Future<void> showServerEditor(
  BuildContext context,
  ServerEditorDelegate delegate,
  ServerConfig? existing,
) {
  final l10n = AppLocalizations.of(context);
  final strings = poltergeistServerEditorStrings(l10n);
  return showGhostServerEditor(
    context,
    _PoltergeistEditorSession(delegate, existing, strings),
    existing == null ? null : ghostServerDraftOf(existing),
    strings: strings,
    appearanceStrings: PoltergeistServerAppearanceStrings(l10n),
    monoStyle: poltergeistMonoTextStyle,
    hexStyle: poltergeistMonoTextStyle,
    // Poltergeist shows the start folder; Séance's editor hides it.
    fields: const {GhostServerOptionalField.startDirectory},
    sections: [_TransferLimitSection(delegate, existing?.id, l10n)],
    onCopyError: ApplicationErrorReporter().report,
  );
}

/// One editor's session over the app's [ServerEditorDelegate]: the stored
/// config the draft edits, the save rules that turn a draft and the boxes
/// as typed into a config and a credential, and the connection test's log.
final class _PoltergeistEditorSession extends GhostServerEditorDelegate {
  _PoltergeistEditorSession(this._delegate, this._existing, this._strings);

  final ServerEditorDelegate _delegate;
  final ServerConfig? _existing;
  final GhostServerEditorStrings _strings;

  @override
  List<String> get serverGroups => existingServerGroups(_delegate.servers);

  @override
  bool get syncConfigured => _delegate.syncConfigured;

  @override
  Color get themeSeed => _delegate.themeSeed;

  @override
  String newId() => uuidV4();

  @override
  Future<String?> pickIdentityFile() => _delegate.pickIdentityFile();

  /// Nothing is awaited before the stamp and the config are built, and the
  /// draft and the boxes were read when Save was pressed, so an edit made
  /// while the keyring answers is not saved without passing validation.
  @override
  Future<bool> save(GhostServerSave save) async {
    final existing = _existing;
    // Against the freshest copy this device holds, not the one captured when
    // the editor opened: a round that pulled a newer record meanwhile is
    // exactly the record this stamp has to outrank.
    final latest = existing == null
        ? null
        : _delegate.servers
              .where((s) => s.id == existing.id)
              .map((s) => s.updatedAt)
              .fold<int>(existing.updatedAt, math.max);
    final now = nextUpdatedAt(
      latest,
      now: DateTime.now().millisecondsSinceEpoch,
    );

    final existingRef = existing?.secretRef;
    final entry = save.credential;
    final auth = authMethodOfGhost(save.draft.authMethod);
    // Its `secretRef` is the one thing that cannot be known yet — whether a
    // credential is written depends on what the vault answers — so it is
    // built against the existing ref and corrected below.
    final formConfig = serverConfigOfGhostDraft(
      save.draft,
      existing: existing,
      secretRef: existingRef,
      now: now,
    );
    // Only when a referenced key's passphrase is about to be written over an
    // entry that may hold a PEM: every other branch replaces the entry whole.
    // A locked keyring throws, and the editor reports it like a failed save
    // rather than writing the passphrase over the key it was stored beside.
    Secret? stored;
    if (existingRef != null &&
        plannedCredentialReadsStored(
          auth: auth,
          referenceKeyFile: entry.referenceKeyFile,
          keyPassphrase: entry.keyPassphrase,
        )) {
      stored = await _delegate.readSecret(existingRef);
    }
    final secretId = existingRef ?? save.draftSecretId;
    final secret = plannedCredential(
      auth: auth,
      referenceKeyFile: entry.referenceKeyFile,
      password: entry.password,
      keyPem: entry.keyPem,
      keyPassphrase: entry.keyPassphrase,
      secretId: secretId,
      stored: stored,
    );

    final config = secret != null && secretId != existingRef
        // `updatedAt` is not restated here: the draft's config already
        // carries the same `now`.
        ? formConfig.copyWith(secretRef: secretId)
        : formConfig;
    // The vault write inside throws when the OS keyring is unavailable.
    await _delegate.save(config, secret: secret);
    return secret != null;
  }

  @override
  Future<GhostTestReport> testConnection(
    GhostServerDraft draft,
    GhostCredentialDraft credential,
  ) async {
    final log = SshConnectionLog();
    final config = serverConfigOfGhostDraft(
      draft,
      existing: _existing,
      secretRef: _existing?.secretRef,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      final result = await _delegate.testConnection(
        config,
        draftPassword: credential.password,
        draftPrivateKey: credential.privateKeyPem,
        draftKeyPassphrase: credential.keyPassphrase,
        log: log,
      );
      log.freeze();
      return ghostTestReportOf(result);
    } catch (error) {
      // runConnectionTest turns every failure it can see into a result, so
      // reaching here means something outside it went wrong. The same inline
      // report an expected failure gets, not a toast: what went wrong is by
      // definition unexpected, so it is the detail worth keeping.
      log.freeze();
      return GhostTestReport(
        ok: false,
        summary: _strings.testFailedSummary,
        notes: ['$error'],
        log: log.toString(),
      );
    }
  }
}

/// D37's override: how many files the queue moves to or from this server at
/// once. Kept apart from the connection fields it sits near because it never
/// reaches the config — it is stored on this device alone — and written only
/// after the server saved, and only when the choice changed, so a settings
/// file that cannot be written does not fail a Save that never touched it.
final class _TransferLimitSection implements GhostServerEditorSection {
  _TransferLimitSection(this._delegate, String? serverId, this._l10n)
    : _stored = serverId == null
          ? null
          : _delegate.transferConcurrencyFor(serverId) {
    _chosen = _stored;
  }

  final ServerEditorDelegate _delegate;
  final AppLocalizations _l10n;

  /// This server's own cap, null to follow the default; and the one stored,
  /// so a Save writes it only when it changed.
  TransferConcurrency? _stored;
  TransferConcurrency? _chosen;

  @override
  Widget build(BuildContext context) => _TransferLimitField(section: this);

  @override
  Future<void> Function(String serverId)? capture() {
    final chosen = _chosen;
    if (chosen == _stored) return null;
    return (serverId) async {
      await _delegate.saveTransferConcurrency(serverId, chosen);
      _stored = chosen;
    };
  }

  @override
  String failureMessage(Object error) =>
      _l10n.serverEditorTransferLimitSaveFailed('$error');
}

class _TransferLimitField extends StatefulWidget {
  const _TransferLimitField({required this.section});

  final _TransferLimitSection section;

  @override
  State<_TransferLimitField> createState() => _TransferLimitFieldState();
}

class _TransferLimitFieldState extends State<_TransferLimitField> {
  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final l10n = AppLocalizations.of(context);
    String describe(TransferConcurrency value) =>
        value.files?.toString() ?? l10n.transferLimitAutomatic;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        DropdownButtonFormField<_TransferLimitChoice>(
          key: const ValueKey('serverEditor.transferLimit'),
          initialValue: _TransferLimitChoice(section._chosen),
          decoration: InputDecoration(
            labelText: l10n.serverEditorTransferLimit,
          ),
          items: [
            DropdownMenuItem(
              value: const _TransferLimitChoice(null),
              child: Text(
                l10n.serverEditorTransferLimitDefault(
                  describe(section._delegate.defaultTransferConcurrency),
                ),
              ),
            ),
            DropdownMenuItem(
              value: const _TransferLimitChoice(
                TransferConcurrency.automatic(),
              ),
              child: Text(l10n.transferLimitAutomatic),
            ),
            for (final files in transferConcurrencyChoices)
              DropdownMenuItem(
                value: _TransferLimitChoice(TransferConcurrency.fixed(files)),
                child: Text('$files'),
              ),
          ],
          onChanged: (choice) => setState(() => section._chosen = choice?.own),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.serverEditorTransferLimitNote,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
        ),
      ],
    );
  }
}

/// One entry of the "Simultaneous transfers" menu: the server's own cap, or
/// null for the default. A wrapper because a dropdown reads a null value as
/// nothing selected.
@immutable
class _TransferLimitChoice {
  const _TransferLimitChoice(this.own);

  final TransferConcurrency? own;

  @override
  bool operator ==(Object other) =>
      other is _TransferLimitChoice && other.own == own;

  @override
  int get hashCode => own.hashCode;
}
