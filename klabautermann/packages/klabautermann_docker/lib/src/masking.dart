import 'package:meta/meta.dart';

/// 03 §8.9: env and label values are masked when their key matches this
/// pattern (case-insensitive). `KEY` deliberately over-matches words such
/// as `MONKEY`; over-masking is the safe direction.
final RegExp secretKeyPattern = RegExp(
  r'PASS|PASSWORD|SECRET|TOKEN|KEY|PRIVATE|CREDENTIAL|AUTH|DSN|DATABASE_URL',
  caseSensitive: false,
);

/// 03 §8.9: the `user:pass@` of `scheme://user:pass@` credentials, read
/// after the `://`. The user may be empty (`redis://:pass@host`). The
/// password runs to the last `@` before a `/` or whitespace, so an
/// unescaped `@`, `?` or `#` in it stays hidden. The price is that an
/// `@` in a query or fragment of a URL without a path
/// (`http://host:80?to=a@b`) masks from the port on; over-masking is the
/// safe direction.
final RegExp _urlCredentialPattern = RegExp(r'([^/@\s:]*):[^/\s]+@');

/// A userinfo without a colon (`https://<token>@host`), read after the
/// `://` of an `http` or `https` URL: there it is a token (a forge's
/// access token, a DSN's key) more often than a login name. Other schemes
/// keep theirs (`ssh://git@host`, `postgres://app@db`). `?` and `#` end
/// it, so an `@` in a query or fragment masks nothing.
final RegExp _urlTokenPattern = RegExp(r'[^/@\s:?#]+@');

/// Whether the code unit [unit] is an ASCII letter, which a URL scheme
/// starts with. Code units, not a regular expression per character,
/// keep the scan of a 128 KiB argument cheap.
bool _isLetter(int unit) =>
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);

/// Whether the code unit [unit] is a URL scheme character
/// (`[A-Za-z0-9+.-]`).
bool _isSchemeCharacter(int unit) =>
    _isLetter(unit) ||
    (unit >= 0x30 && unit <= 0x39) ||
    unit == 0x2B ||
    unit == 0x2D ||
    unit == 0x2E;

/// Whether [key] names a secret under the 03 §8.9 rules.
bool isSecretKey(String key) => secretKeyPattern.hasMatch(key);

/// A value plus its display form. The real text of a secret is reachable
/// only through [reveal]; [display] and [toString] carry the mask, so a
/// view that renders the field by accident cannot leak it (03 §8.9).
@immutable
final class MaskedValue {
  const MaskedValue._(this.display, this._secret);

  /// The fixed mask text shown in place of a secret.
  static const String maskToken = '********';

  /// A value that is safe to show as-is.
  factory MaskedValue.plain(String value) => MaskedValue._(value, null);

  /// A value hidden behind [maskToken]; the real text stays in [_secret].
  factory MaskedValue.secret(String value) => MaskedValue._(maskToken, value);

  /// A value shown partially redacted; [display] is safe to render and
  /// [secret] is the original text behind [reveal].
  factory MaskedValue.redacted(String display, String secret) =>
      MaskedValue._(display, secret);

  final String display;
  final String? _secret;

  /// True when [display] hides a secret.
  bool get isMasked => _secret != null;

  /// The real text of a masked value, for the explicit reveal action of
  /// 03 §8.9. Null for a plain value (its [display] is already real).
  String? reveal() => _secret;

  @override
  String toString() => display;

  @override
  bool operator ==(Object other) =>
      other is MaskedValue &&
      other.display == display &&
      other._secret == _secret;

  @override
  int get hashCode => Object.hash(display, _secret);
}

/// Masks [value] when [key] is a secret key (03 §8.9), otherwise returns
/// it unchanged.
MaskedValue maskedValueFor(String key, String value) =>
    isSecretKey(key) ? MaskedValue.secret(value) : MaskedValue.plain(value);

/// Masks the value half of a `KEY=VALUE` string; a string without `=` is
/// treated as a bare key.
MaskedValue maskedEnvEntry(String entry) {
  final eq = entry.indexOf('=');
  if (eq < 0) return MaskedValue.plain(entry);
  return maskedValueWithUrlCheck(
    entry.substring(0, eq),
    entry.substring(eq + 1),
  );
}

/// Masks every value in [labels] according to its key, and any URL
/// credentials in a value whose key is not secret (03 §8.9).
Map<String, MaskedValue> maskedLabels(Map<String, String> labels) => {
  for (final e in labels.entries)
    e.key: maskedValueWithUrlCheck(e.key, e.value),
};

/// Replaces `scheme://user:pass@` credentials in [text], and an http
/// URL's userinfo that is one token, with the mask token (03 §8.9: URL
/// credentials are a secret even in a value whose key does not look
/// secret).
String maskUrlCredentials(String text) {
  final spans = urlCredentialSpans(text);
  if (spans.isEmpty) return text;

  final masked = StringBuffer();
  var copied = 0;
  for (final (start, end) in spans) {
    masked
      ..write(text.substring(copied, start))
      ..write(MaskedValue.maskToken);
    copied = end;
  }
  return (masked..write(text.substring(copied))).toString();
}

/// The `pass` of each `scheme://user:pass@` in [text], and the token of
/// each `http(s)://token@`, as start and end offsets in order (03 §8.9).
///
/// The text may come from a host, a process argument of up to 128 KiB for
/// one, so the scan is linear: it looks for each `://` and checks the
/// characters before it once, where one regular expression for the whole
/// rule would restart at every character of a long scheme-like run.
List<(int, int)> urlCredentialSpans(String text) {
  final spans = <(int, int)>[];
  // The end of the last credentials found; a scheme starts after it.
  var copied = 0;
  for (
    var separator = text.indexOf('://');
    separator != -1;
    separator = text.indexOf('://', separator + 1)
  ) {
    if (!_endsScheme(text, copied, separator)) continue;
    final credentials = _urlCredentialPattern.matchAsPrefix(
      text,
      separator + 3,
    );
    if (credentials != null) {
      spans.add((
        separator + 3 + credentials[1]!.length + 1,
        credentials.end - 1,
      ));
      copied = credentials.end;
      continue;
    }

    if (!_endsHttpScheme(text, separator)) continue;
    final token = _urlTokenPattern.matchAsPrefix(text, separator + 3);
    if (token == null) continue;
    spans.add((separator + 3, token.end - 1));
    copied = token.end;
  }
  return spans;
}

/// Whether the run of scheme characters that ends at [end], starting at
/// [start] or later, holds a letter a scheme can start with. The runs
/// before two `://` never overlap, since `:` ends a run.
bool _endsScheme(String text, int start, int end) {
  var letter = false;
  for (var at = end - 1; at >= start; at--) {
    final unit = text.codeUnitAt(at);
    if (!_isSchemeCharacter(unit)) break;
    letter = letter || _isLetter(unit);
  }
  return letter;
}

/// Whether the scheme that ends at [end] is `http` or `https`, alone or
/// after a `+` (`git+https`), in any case.
bool _endsHttpScheme(String text, int end) {
  var start = end;
  while (start > 0 &&
      end - start < 6 &&
      _isLetter(text.codeUnitAt(start - 1))) {
    start--;
  }
  if (start > 0) {
    final before = text.codeUnitAt(start - 1);
    if (before != 0x2B && _isSchemeCharacter(before)) return false;
  }
  final scheme = text.substring(start, end).toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

/// A value whose key is not secret but which contains URL credentials is
/// still masked (03 §8.9).
MaskedValue maskedValueWithUrlCheck(String key, String value) {
  if (isSecretKey(key)) return MaskedValue.secret(value);
  final masked = maskUrlCredentials(value);
  return masked == value
      ? MaskedValue.plain(value)
      : MaskedValue.redacted(masked, value);
}

/// [options], a driver's (a volume's `Options`, a log driver's `Config`),
/// as they may be shown (03 §8.9): the value of a secret key is the mask
/// token (`splunk-token`), and so is, to the value's end, what follows a
/// secret sub-key of a comma-separated list (a CIFS volume's
/// `o=username=u,password=p`) and each URL's credentials (`loki-url`).
/// Keys stay, so a reader can still ask for one. There is no reveal: the
/// options are shown as facts, never edited.
Map<String, String> maskedDriverOptions(Map<String, String> options) => {
  for (final MapEntry(:key, :value) in options.entries)
    key: isSecretKey(key)
        ? MaskedValue.maskToken
        : maskUrlCredentials(_maskedSubOptions(value)),
};

/// [value] with everything after the `=` of its first secret sub-key
/// masked. To the end, not to the next comma: a password may hold one.
String _maskedSubOptions(String value) {
  var start = 0;
  while (start < value.length) {
    final comma = value.indexOf(',', start);
    final end = comma == -1 ? value.length : comma;
    final equals = value.indexOf('=', start);
    if (equals != -1 &&
        equals < end &&
        isSecretKey(value.substring(start, equals))) {
      return equals == value.length - 1
          ? value
          : '${value.substring(0, equals + 1)}${MaskedValue.maskToken}';
    }
    start = end + 1;
  }
  return value;
}
