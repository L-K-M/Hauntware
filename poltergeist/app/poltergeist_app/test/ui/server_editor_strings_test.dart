import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart' show GhostServerEditorStrings;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/ghost_servers_adapter.dart';
import 'package:poltergeist_app/ui/server_appearance_strings.dart';

/// The server editor's string bag reads every member from the ARB catalog
/// (docs/design/ghost-servers-part2.md, section 8, F5a-1b), in every
/// locale the app ships, and the package's defaults are the same words.
void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    test('every member is its ARB string ($locale)', () {
      final l10n = lookupAppLocalizations(locale);
      final strings = poltergeistServerEditorStrings(l10n);

      for (final (member, arb) in [
        (strings.addTitle, l10n.serverEditorAddTitle),
        (strings.editTitle, l10n.serverEditorEditTitle),
        (strings.label, l10n.serverEditorLabel),
        (strings.host, l10n.serverEditorHost),
        (strings.port, l10n.serverEditorPort),
        (strings.username, l10n.serverEditorUsername),
        (strings.authentication, l10n.serverEditorAuthentication),
        (strings.authAgent, l10n.serverEditorAuthAgent),
        (strings.authPassword, l10n.serverEditorAuthPassword),
        (strings.authPrivateKey, l10n.serverEditorAuthPrivateKey),
        (strings.agentInfo, l10n.serverEditorAgentInfo),
        (strings.passwordLabel, l10n.serverEditorPasswordLabel),
        (strings.referenceKeyTitle, l10n.serverEditorReferenceKeyTitle),
        (strings.referenceKeySubtitle, l10n.serverEditorReferenceKeySubtitle),
        (strings.identityFilePath, l10n.serverEditorIdentityFilePath),
        (strings.identityFileHint, l10n.serverEditorIdentityFileHint),
        (strings.browse, l10n.serverEditorBrowse),
        (strings.privateKeyPem, l10n.serverEditorPrivateKeyPem),
        (strings.keyPassphrase, l10n.serverEditorKeyPassphrase),
        (strings.startDirectory, l10n.serverEditorStartDirectory),
        (strings.startDirectoryHint, l10n.serverEditorStartDirectoryHint),
        (strings.startDirectoryNote, l10n.serverEditorStartDirectoryNote),
        (strings.startDirectoryInvalid, l10n.serverEditorStartDirectoryInvalid),
        (strings.loginScript, l10n.serverEditorLoginScript),
        (strings.loginScriptHint, l10n.serverEditorLoginScriptHint),
        (strings.loginScriptNote, l10n.serverEditorLoginScriptNote),
        (strings.appearance, l10n.serverEditorAppearance),
        (strings.group, l10n.serverEditorGroup),
        (strings.groupHint, l10n.serverEditorGroupHint),
        (strings.colour, l10n.serverEditorColour),
        (strings.mark, l10n.serverEditorMark),
        (strings.chooseMark, l10n.serverEditorChooseMark),
        (strings.defaultMarkTooltip, l10n.serverEditorDefaultMarkTooltip),
        (strings.customColour, l10n.serverEditorCustomColour),
        (strings.syncSecretTitle, l10n.serverEditorSyncSecretTitle),
        (strings.syncSecretExcluded, l10n.serverEditorSyncSecretExcluded),
        (strings.syncSecretSubtitle, l10n.serverEditorSyncSecretSubtitle),
        (strings.excludeTitle, l10n.serverEditorExcludeTitle),
        (strings.excludeOnSubtitle, l10n.serverEditorExcludeOnSubtitle),
        (strings.excludeOffSubtitle, l10n.serverEditorExcludeOffSubtitle),
        (strings.excludeConfirmTitle, l10n.serverEditorExcludeConfirmTitle),
        (strings.excludeConfirmBody, l10n.serverEditorExcludeConfirmBody),
        (strings.excludeConfirmCancel, l10n.serverEditorExcludeConfirmCancel),
        (strings.excludeConfirmAction, l10n.serverEditorExcludeConfirmAction),
        (strings.test, l10n.serverEditorTest),
        (strings.testing, l10n.serverEditorTesting),
        (strings.testingSemantic, l10n.serverEditorTestingSemantic),
        (strings.testFailedSummary, l10n.serverEditorTestFailedSummary),
        (strings.testDisclaimer, l10n.serverEditorTestDisclaimer),
        (strings.cancel, l10n.serverEditorCancel),
        (strings.save, l10n.serverEditorSave),
        (strings.required, l10n.serverEditorRequired),
        (strings.portRange, l10n.serverEditorPortRange),
      ]) {
        expect(member, arb);
      }
      expect(
        strings.saveFailed('locked'),
        l10n.serverEditorSaveFailed('locked'),
      );
      expect(
        strings.customColourValue('#1E90FF'),
        l10n.serverEditorCustomColourValue('#1E90FF'),
      );
      expect(strings.testStrings.succeeded, l10n.connectionTestSucceeded);
      expect(strings.testStrings.failed, l10n.connectionTestFailed);
      expect(strings.logStrings.title, l10n.connectionLogTitle);
      expect(strings.logStrings.copy, l10n.connectionLogCopy);
      expect(strings.logStrings.copied, l10n.connectionLogCopied);
      expect(strings.logStrings.copyFailed, l10n.connectionLogCopyFailed);
      expect(strings.logStrings.empty, l10n.connectionLogEmpty);
      expect(strings.colorPickerStrings, isA<PoltergeistColorPickerStrings>());
      expect(
        strings.colorPickerStrings.hexLabel,
        PoltergeistColorPickerStrings(l10n).hexLabel,
      );
    });
  }

  test('the package defaults are the English catalog', () {
    // Séance passes no bag, so its words are the defaults; section 4 found
    // them identical to Poltergeist's English ones.
    final english = poltergeistServerEditorStrings(
      lookupAppLocalizations(const Locale('en')),
    );
    const defaults = GhostServerEditorStrings();
    for (final (byDefault, inEnglish, member) in [
      (defaults.addTitle, english.addTitle, 'addTitle'),
      (defaults.editTitle, english.editTitle, 'editTitle'),
      (defaults.label, english.label, 'label'),
      (defaults.host, english.host, 'host'),
      (defaults.port, english.port, 'port'),
      (defaults.username, english.username, 'username'),
      (defaults.authentication, english.authentication, 'authentication'),
      (defaults.authAgent, english.authAgent, 'authAgent'),
      (defaults.authPassword, english.authPassword, 'authPassword'),
      (defaults.authPrivateKey, english.authPrivateKey, 'authPrivateKey'),
      (defaults.agentInfo, english.agentInfo, 'agentInfo'),
      (defaults.passwordLabel, english.passwordLabel, 'passwordLabel'),
      (
        defaults.referenceKeyTitle,
        english.referenceKeyTitle,
        'referenceKeyTitle',
      ),
      (
        defaults.referenceKeySubtitle,
        english.referenceKeySubtitle,
        'referenceKeySubtitle',
      ),
      (defaults.identityFilePath, english.identityFilePath, 'identityFilePath'),
      (defaults.identityFileHint, english.identityFileHint, 'identityFileHint'),
      (defaults.browse, english.browse, 'browse'),
      (defaults.privateKeyPem, english.privateKeyPem, 'privateKeyPem'),
      (defaults.keyPassphrase, english.keyPassphrase, 'keyPassphrase'),
      (defaults.startDirectory, english.startDirectory, 'startDirectory'),
      (
        defaults.startDirectoryHint,
        english.startDirectoryHint,
        'startDirectoryHint',
      ),
      (
        defaults.startDirectoryNote,
        english.startDirectoryNote,
        'startDirectoryNote',
      ),
      (
        defaults.startDirectoryInvalid,
        english.startDirectoryInvalid,
        'startDirectoryInvalid',
      ),
      (defaults.loginScript, english.loginScript, 'loginScript'),
      (defaults.loginScriptHint, english.loginScriptHint, 'loginScriptHint'),
      (defaults.loginScriptNote, english.loginScriptNote, 'loginScriptNote'),
      (defaults.appearance, english.appearance, 'appearance'),
      (defaults.group, english.group, 'group'),
      (defaults.groupHint, english.groupHint, 'groupHint'),
      (defaults.colour, english.colour, 'colour'),
      (defaults.mark, english.mark, 'mark'),
      (defaults.chooseMark, english.chooseMark, 'chooseMark'),
      (
        defaults.defaultMarkTooltip,
        english.defaultMarkTooltip,
        'defaultMarkTooltip',
      ),
      (defaults.customColour, english.customColour, 'customColour'),
      (defaults.syncSecretTitle, english.syncSecretTitle, 'syncSecretTitle'),
      (
        defaults.syncSecretExcluded,
        english.syncSecretExcluded,
        'syncSecretExcluded',
      ),
      (
        defaults.syncSecretSubtitle,
        english.syncSecretSubtitle,
        'syncSecretSubtitle',
      ),
      (defaults.excludeTitle, english.excludeTitle, 'excludeTitle'),
      (
        defaults.excludeOnSubtitle,
        english.excludeOnSubtitle,
        'excludeOnSubtitle',
      ),
      (
        defaults.excludeOffSubtitle,
        english.excludeOffSubtitle,
        'excludeOffSubtitle',
      ),
      (
        defaults.excludeConfirmTitle,
        english.excludeConfirmTitle,
        'excludeConfirmTitle',
      ),
      (
        defaults.excludeConfirmBody,
        english.excludeConfirmBody,
        'excludeConfirmBody',
      ),
      (
        defaults.excludeConfirmCancel,
        english.excludeConfirmCancel,
        'excludeConfirmCancel',
      ),
      (
        defaults.excludeConfirmAction,
        english.excludeConfirmAction,
        'excludeConfirmAction',
      ),
      (defaults.test, english.test, 'test'),
      (defaults.testing, english.testing, 'testing'),
      (defaults.testingSemantic, english.testingSemantic, 'testingSemantic'),
      (
        defaults.testFailedSummary,
        english.testFailedSummary,
        'testFailedSummary',
      ),
      (defaults.testDisclaimer, english.testDisclaimer, 'testDisclaimer'),
      (defaults.cancel, english.cancel, 'cancel'),
      (defaults.save, english.save, 'save'),
      (defaults.required, english.required, 'required'),
      (defaults.portRange, english.portRange, 'portRange'),
    ]) {
      expect(byDefault, inEnglish, reason: member);
    }
    expect(defaults.saveFailed('locked'), english.saveFailed('locked'));
    expect(
      defaults.customColourValue('#1E90FF'),
      english.customColourValue('#1E90FF'),
    );
  });
}
