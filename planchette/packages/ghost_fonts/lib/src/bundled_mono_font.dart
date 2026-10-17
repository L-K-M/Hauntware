/// The package that registers the bundled families. Flutter names a
/// package's font family `packages/<package>/<family>`.
const String _package = 'ghost_fonts';

/// A monospace family every Ghost app ships, so code and terminal text look
/// the same on every platform instead of depending on what is installed.
///
enum BundledMonoFont {
  /// Narrow and tall, so a window holds more columns. Séance's terminal
  /// default. A subset of the Term variant, whose arrows and symbols stay
  /// one cell wide.
  iosevkaTerm('Iosevka Term'),

  /// Large x-height and open shapes. The default for code and editors.
  jetBrainsMono('JetBrains Mono'),

  /// The classic ligature face. Upright only: italics are slanted.
  firaCode('Fira Code'),

  /// Rounded, with cursive italics.
  mapleMono('Maple Mono'),
  cascadiaCode('Cascadia Code'),
  victorMono('Victor Mono'),
  lilex('Lilex'),
  zeroXProto('0xProto'),
  monaspaceNeon('Monaspace Neon'),
  monaspaceArgon('Monaspace Argon'),
  monaspaceXenon('Monaspace Xenon'),
  monaspaceRadon('Monaspace Radon'),
  monaspaceKrypton('Monaspace Krypton'),
  martianMono('Martian Mono'),
  geistMono('Geist Mono'),
  intelOneMono('Intel One Mono'),
  fragmentMono('Fragment Mono'),
  googleSansCode('Google Sans Code'),
  commitMono('Commit Mono'),
  departureMono('Departure Mono');

  const BundledMonoFont(this.displayName);

  /// The name people see and settings store, such as 'Iosevka Term'.
  final String displayName;

  /// The family to hand a `TextStyle`.
  String get family => 'packages/$_package/$displayName';

  /// Whether the shipped face has programming ligatures to preview.
  bool get hasProgrammingLigatures => switch (this) {
    googleSansCode || departureMono => false,
    _ => true,
  };

  /// The bundled font [name] refers to, ignoring case and surrounding
  /// spaces, or null when it names some other family.
  static BundledMonoFont? named(String name) {
    final wanted = name.trim().toLowerCase();
    for (final font in values) {
      if (font.displayName.toLowerCase() == wanted) return font;
    }
    return null;
  }
}

/// The family to draw a stored or typed family [name] in: the bundled copy
/// when [name] is a bundled font, so 'Fira Code' works without being
/// installed, otherwise [name] unchanged for the platform to resolve.
String resolveMonoFamily(String name) =>
    BundledMonoFont.named(name)?.family ?? name.trim();

/// The family code and other fixed-width text draws in:
/// [BundledMonoFont.jetBrainsMono]'s, spelled out so apps can use it in
/// constant styles (a test pins the two together).
const String ghostMonoFontFamily = 'packages/$_package/JetBrains Mono';

/// The stack code and other fixed-width text falls back through:
/// [ghostMonoFontFamily], then each platform's own monospace faces for
/// characters it lacks.
///
/// The trailing 'monospace' is the generic family only on Linux and
/// Android; elsewhere the platform skips it.
const List<String> ghostMonoFontFamilies = [
  ghostMonoFontFamily,
  'SF Mono',
  'Menlo',
  'Consolas',
  'DejaVu Sans Mono',
  'monospace',
];
