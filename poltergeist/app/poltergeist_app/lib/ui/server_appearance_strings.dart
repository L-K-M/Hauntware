// The shared pickers' words from this app's ARB catalog (D20): ghost_marks'
// server mark and colour pickers and ghost_ui's colour picker take string
// bags, and these fill them.
import 'package:ghost_marks/ghost_marks.dart';
import 'package:ghost_ui/ghost_ui.dart' show BadgeImageFailure, ColorPickerStrings;

import '../l10n/app_localizations.dart';

/// [ServerAppearanceStrings] from the ARB catalog.
final class PoltergeistServerAppearanceStrings extends ServerAppearanceStrings {
  const PoltergeistServerAppearanceStrings(this._l10n);

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
final class PoltergeistColorPickerStrings extends ColorPickerStrings {
  const PoltergeistColorPickerStrings(this._l10n);

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
