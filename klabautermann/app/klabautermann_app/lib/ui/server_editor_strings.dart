// The shared server editor's words from this app's ARB catalog (03 §10.10's
// adapter-file convention): ghost_servers' editor, ghost_marks' mark and
// colour pickers and ghost_ui's colour picker take string bags, and these
// fill them. Ported from Poltergeist's adapters, key for key.
import 'package:ghost_marks/ghost_marks.dart';
import 'package:ghost_servers/ghost_servers.dart' show GhostServerEditorStrings;
import 'package:ghost_ui/ghost_ui.dart'
    show BadgeImageFailure, ColorPickerStrings;

import '../l10n/app_localizations.dart';

/// The server editor's words in ARB. Every member has a key of its own,
/// and the custom colour picker takes the app's colour picker words. The
/// connection test's report and transcript keep the package's English
/// until Test connection arrives (M5 plan M09b).
GhostServerEditorStrings klabautermannServerEditorStrings(
  AppLocalizations l10n,
) => GhostServerEditorStrings(
  addTitle: l10n.serverEditorAddTitle,
  editTitle: l10n.serverEditorEditTitle,
  label: l10n.serverEditorLabel,
  host: l10n.serverEditorHost,
  port: l10n.serverEditorPort,
  username: l10n.serverEditorUsername,
  authentication: l10n.serverEditorAuthentication,
  authAgent: l10n.serverEditorAuthAgent,
  authPassword: l10n.serverEditorAuthPassword,
  authPrivateKey: l10n.serverEditorAuthPrivateKey,
  agentInfo: l10n.serverEditorAgentInfo,
  passwordLabel: l10n.serverEditorPasswordLabel,
  referenceKeyTitle: l10n.serverEditorReferenceKeyTitle,
  referenceKeySubtitle: l10n.serverEditorReferenceKeySubtitle,
  identityFilePath: l10n.serverEditorIdentityFilePath,
  identityFileHint: l10n.serverEditorIdentityFileHint,
  browse: l10n.serverEditorBrowse,
  privateKeyPem: l10n.serverEditorPrivateKeyPem,
  keyPassphrase: l10n.serverEditorKeyPassphrase,
  startDirectory: l10n.serverEditorStartDirectory,
  startDirectoryHint: l10n.serverEditorStartDirectoryHint,
  startDirectoryNote: l10n.serverEditorStartDirectoryNote,
  startDirectoryInvalid: l10n.serverEditorStartDirectoryInvalid,
  loginScript: l10n.serverEditorLoginScript,
  loginScriptHint: l10n.serverEditorLoginScriptHint,
  loginScriptNote: l10n.serverEditorLoginScriptNote,
  appearance: l10n.serverEditorAppearance,
  group: l10n.serverEditorGroup,
  groupHint: l10n.serverEditorGroupHint,
  colour: l10n.serverEditorColour,
  mark: l10n.serverEditorMark,
  chooseMark: l10n.serverEditorChooseMark,
  defaultMarkTooltip: l10n.serverEditorDefaultMarkTooltip,
  customColour: l10n.serverEditorCustomColour,
  syncSecretTitle: l10n.serverEditorSyncSecretTitle,
  syncSecretExcluded: l10n.serverEditorSyncSecretExcluded,
  syncSecretSubtitle: l10n.serverEditorSyncSecretSubtitle,
  excludeTitle: l10n.serverEditorExcludeTitle,
  excludeOnSubtitle: l10n.serverEditorExcludeOnSubtitle,
  excludeOffSubtitle: l10n.serverEditorExcludeOffSubtitle,
  excludeConfirmTitle: l10n.serverEditorExcludeConfirmTitle,
  excludeConfirmBody: l10n.serverEditorExcludeConfirmBody,
  excludeConfirmCancel: l10n.serverEditorExcludeConfirmCancel,
  excludeConfirmAction: l10n.serverEditorExcludeConfirmAction,
  test: l10n.serverEditorTest,
  testing: l10n.serverEditorTesting,
  testingSemantic: l10n.serverEditorTestingSemantic,
  testFailedSummary: l10n.serverEditorTestFailedSummary,
  testDisclaimer: l10n.serverEditorTestDisclaimer,
  cancel: l10n.serverEditorCancel,
  save: l10n.serverEditorSave,
  required: l10n.serverEditorRequired,
  portRange: l10n.serverEditorPortRange,
  saveFailed: l10n.serverEditorSaveFailed,
  customColourValue: l10n.serverEditorCustomColourValue,
  colorPickerStrings: KlabautermannColorPickerStrings(l10n),
);

/// [ServerAppearanceStrings] from the ARB catalog.
final class KlabautermannServerAppearanceStrings
    extends ServerAppearanceStrings {
  const KlabautermannServerAppearanceStrings(this._l10n);

  final AppLocalizations _l10n;

  @override
  String get markPickerTitle => _l10n.serverMarkPickerTitle;

  @override
  String get iconsTab => _l10n.serverMarkPickerIconsTab;

  @override
  String get emojiTab => _l10n.serverMarkPickerEmojiTab;

  @override
  String get imageTab => _l10n.serverMarkPickerImageTab;

  @override
  String get cancel => _l10n.serverMarkPickerCancel;

  @override
  String get iconSearchHint => _l10n.serverMarkPickerSearchHint;

  @override
  String get iconSearchEmpty => _l10n.serverMarkPickerNoMatch;

  @override
  String get defaultMarkHeading => _l10n.serverMarkPickerDefault;

  @override
  String get emojiHintMacOS => _l10n.serverMarkPickerEmojiHintMacOS;

  @override
  String get emojiHintWindows => _l10n.serverMarkPickerEmojiHintWindows;

  @override
  String get emojiHintLinux => _l10n.serverMarkPickerEmojiHintLinux;

  @override
  String get emojiHintOther => _l10n.serverMarkPickerEmojiHintOther;

  @override
  String get emojiFieldLabel => _l10n.serverMarkPickerAnyEmoji;

  @override
  String get emojiFieldError => _l10n.serverMarkPickerOneEmoji;

  @override
  String get emojiUse => _l10n.serverMarkPickerUse;

  @override
  String get emojiFontNote => _l10n.serverMarkPickerEmojiFontNote;

  @override
  String get imageOpenFailed => _l10n.serverMarkPickerOpenFailed;

  @override
  String imageFailure(BadgeImageFailure failure) => switch (failure) {
    BadgeImageFailure.tooLarge => _l10n.serverMarkPickerTooLarge,
    BadgeImageFailure.undecodable => _l10n.serverMarkPickerUndecodable,
    BadgeImageFailure.encodeFailed => _l10n.serverMarkPickerEncodeFailed,
    BadgeImageFailure.incompressible => _l10n.serverMarkPickerIncompressible,
  };

  @override
  String get imageAbsent => _l10n.serverMarkPickerNoImage;

  @override
  String get imagePresent => _l10n.serverMarkPickerHasImage;

  @override
  String get imageChoose => _l10n.serverMarkPickerChooseImage;

  @override
  String get imageReplace => _l10n.serverMarkPickerReplaceImage;

  @override
  String get imageRemove => _l10n.serverMarkPickerRemoveImage;

  @override
  String get imageFormatsDesktop => _l10n.serverMarkPickerImageFormats;

  @override
  String get imageFormatsIos => _l10n.serverMarkPickerImageFormatsIos;

  @override
  String imageExplanation(String formats, int side) =>
      _l10n.serverMarkPickerImageExplanation(formats, side);

  @override
  String get serverColorTitle => _l10n.serverColorPickerTitle;

  @override
  String get serverColorHint => _l10n.serverColorPickerHint;
}

/// [ColorPickerStrings] from the ARB catalog.
final class KlabautermannColorPickerStrings extends ColorPickerStrings {
  const KlabautermannColorPickerStrings(this._l10n);

  final AppLocalizations _l10n;

  @override
  String get hexLabel => _l10n.colorPickerHexLabel;

  @override
  String get hexError => _l10n.colorPickerHexError;

  @override
  String get hexErrorAlpha => _l10n.colorPickerHexErrorAlpha;

  @override
  String get hue => _l10n.colorPickerHue;

  @override
  String get saturation => _l10n.colorPickerSaturation;

  @override
  String get brightness => _l10n.colorPickerBrightness;

  @override
  String get opacity => _l10n.colorPickerOpacity;

  @override
  String degrees(int degrees) => _l10n.colorPickerDegrees(degrees);

  @override
  String percent(int percent) => _l10n.colorPickerPercent(percent);

  @override
  String get cancel => _l10n.colorPickerCancel;

  @override
  String get use => _l10n.colorPickerUse;
}
