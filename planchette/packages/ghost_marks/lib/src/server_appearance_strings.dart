import 'package:ghost_ui/ghost_ui.dart' show BadgeImageFailure;

/// The server mark and colour pickers' words, English by default (Séance's).
/// A host with localized copy subclasses it and overrides every member.
///
/// Glyph and colour names are not here: they are vocabulary
/// (`serverIconLabel`, `serverColorLabel`), the same in every language a
/// host ships.
class ServerAppearanceStrings {
  const ServerAppearanceStrings();

  String get markPickerTitle => 'Server mark';
  String get iconsTab => 'Icons';
  String get emojiTab => 'Emoji';
  String get imageTab => 'Image';
  String get cancel => 'Cancel';

  String get iconSearchHint => 'Search icons — try k8s, psql, prod…';
  String get iconSearchEmpty => 'No icon matches.';

  /// The heading over the default glyph in the Icons tab.
  String get defaultMarkHeading => 'Default';

  /// How to reach the platform's emoji picker.
  String get emojiHintMacOS =>
      'Press Control-Command-Space for the system emoji picker.';
  String get emojiHintWindows => 'Press Windows-. for the system emoji picker.';
  String get emojiHintLinux =>
      'Your desktop may offer an emoji picker with Control-Shift-E or '
      'Control-.';
  String get emojiHintOther => 'Switch your keyboard to emoji.';

  String get emojiFieldLabel => 'Any emoji';
  String get emojiFieldError => 'One emoji, please.';
  String get emojiUse => 'Use';
  String get emojiFontNote =>
      'An emoji is drawn with the system’s own emoji font, so a device '
      'without one shows a box — the icon chosen under Icons is what it falls '
      'back to there.';

  String get imageOpenFailed => 'That file could not be opened. Try another.';

  /// What went wrong importing an image, in terms of what to do about it.
  String imageFailure(BadgeImageFailure failure) => switch (failure) {
    BadgeImageFailure.tooLarge =>
      'That file is too big to read. Crop or export it smaller first.',
    BadgeImageFailure.undecodable => 'That file could not be read as an image.',
    BadgeImageFailure.encodeFailed =>
      'That image could not be prepared. Try again, or pick another.',
    BadgeImageFailure.incompressible =>
      'That image would not fit in a server record even at badge size. Try a '
          'simpler picture — a logo rather than a photograph.',
  };

  String get imageAbsent => 'No image on this server yet.';
  String get imagePresent => 'This server carries an image.';
  String get imageChoose => 'Choose image…';
  String get imageReplace => 'Replace image…';
  String get imageRemove => 'Remove image';

  /// The formats the image tab promises: iOS gets the photo picker, which
  /// holds no SVGs.
  String get imageFormatsDesktop => 'PNG, JPEG, WebP or SVG';
  String get imageFormatsIos => 'PNG, JPEG or WebP';

  /// The image tab's explanation, after the [formats] it accepts; [side] is
  /// the stored image's side in pixels.
  String imageExplanation(String formats, int side) =>
      '$formats. The image is cropped square, stored at $side pixels, and '
      'travels inside this server’s own settings — so it reaches your '
      'other devices with everything else about the server, and never '
      'arrives without it. Anything larger than a badge can show would only '
      'be paid for on every sync. A transparent image shows the server’s '
      'colour through it.';

  /// The server colour picker's title and the line under its sliders.
  String get serverColorTitle => 'Custom colour';
  String get serverColorHint =>
      'Drawn as picked, with the mark kept legible on it in both themes. '
      'Devices running an older version show the nearest of the named colours '
      'instead.';
}
