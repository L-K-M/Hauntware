import 'dart:convert';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart';
import 'package:seance_protocol/seance_protocol.dart';

import '../ssh/remote_file_system.dart';
import '../terminal/shell_command.dart';

/// Owner-only, and executable for a script with an interpreter line.
const int _kScriptMode = 0x1c0; // 0700
const int _kDirectoryMode = 0x1c0; // 0700

const String _kStagingDirectory = '.seance/inbox';

/// The script as the review view shows it: every character that would not
/// otherwise be visible, or that changes how the text around it is laid
/// out, is replaced by a visible escape such as `<U+202E>`.
///
/// The review view is the only place the user reads a proposal before it
/// runs, so it must not render what runs differently from what it shows.
/// Line breaks and tabs are kept (they are laid out, not hidden); everything
/// else in the C0 and C1 control ranges, the bidirectional controls and the
/// zero-width and other format characters are escaped.
class RevealedScript {
  final String text;
  final int hiddenCount;

  const RevealedScript(this.text, this.hiddenCount);

  bool get hasHidden => hiddenCount > 0;
}

RevealedScript revealInvisibles(String script) {
  final out = StringBuffer();
  var hidden = 0;
  for (final rune in script.runes) {
    if (rune == 0x0a || rune == 0x09 || !_isInvisible(rune)) {
      out.writeCharCode(rune);
      continue;
    }
    hidden++;
    out.write('<U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}>');
  }
  return RevealedScript(out.toString(), hidden);
}

/// Spaces other than U+0020, and code points Unicode itself says to render
/// as nothing. The first look like a space but are not one to a shell:
/// `true<U+00A0>|| rm x` reads as a no-op, while bash takes `true<U+00A0>`
/// as one word, fails to find it and runs `rm x`.
final RegExp _deceptiveBlank = RegExp(
  r'[\p{Zs}\p{Default_Ignorable_Code_Point}]',
  unicode: true,
);

/// Braille blank: in neither class, and drawn as nothing.
const int _kBrailleBlank = 0x2800;

bool _isInvisible(int rune) =>
    (rune != 0x20 &&
        (rune == _kBrailleBlank ||
            _deceptiveBlank.hasMatch(String.fromCharCode(rune)))) ||
    rune < 0x20 ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0x00ad ||
    rune == 0x061c ||
    rune == 0x180e ||
    (rune >= 0x200b && rune <= 0x200f) ||
    (rune >= 0x2028 && rune <= 0x202e) ||
    (rune >= 0x2060 && rune <= 0x206f) ||
    rune == 0xfeff ||
    // Variation selectors: zero-width, and able to carry hidden data.
    (rune >= 0xfe00 && rune <= 0xfe0f) ||
    (rune >= 0xe0100 && rune <= 0xe01ef) ||
    (rune >= 0xfff9 && rune <= 0xfffb) ||
    (rune >= 0xe0000 && rune <= 0xe007f);

/// A proposal's script, uploaded and ready to run.
class StagedScript {
  /// Absolute path on the server.
  final String path;

  /// The single line to place in the prompt. The user presses Enter.
  final String commandLine;

  /// SHA-256 of the script bytes, hex, which is also the file name.
  final String sha256Hex;

  const StagedScript({
    required this.path,
    required this.commandLine,
    required this.sha256Hex,
  });
}

class InboxStagingException implements Exception {
  final String message;
  const InboxStagingException(this.message);

  @override
  String toString() => message;
}

/// Upload [proposal]'s script to `~/.seance/inbox/<sha256>.sh` and return
/// the line that runs it.
///
/// The file is named by the hash of the bytes the user reviewed, and the
/// upload's own digest is checked against it, so the line placed in the
/// prompt names exactly those bytes: a different script would be a different
/// line. A script is never pasted as text, because a line break is an Enter
/// keypress (see `PasteSanitizer`) and a multi-line paste would run it.
///
/// A script starting with `#!` is run by path so its interpreter line is
/// honoured; anything else is run with `sh`.
Future<StagedScript> stageProposalScript(
  RemoteFileSystem fs,
  InboxProposal proposal,
) async {
  final bytes = utf8.encode(proposal.script);
  final digest = sha256.convert(bytes).toString();

  final home = await fs.canonicalize('.');
  var directory = home;
  for (final part in _kStagingDirectory.split('/')) {
    directory = remoteJoin(directory, part);
    await _ensureDirectory(fs, directory);
  }

  final path = remoteJoin(directory, '$digest.sh');
  final entry = await fs.upload(
    path,
    Stream.value(bytes),
    length: bytes.length,
    overwrite: true,
    preserveMode: _kScriptMode,
  );
  final uploaded = entry.contentSha256;
  if (uploaded == null) {
    // Every implementation in this repo hashes by default, so this is a
    // backend that cannot; the path still names the reviewed bytes, but the
    // second check did not happen and that should be visible.
    developer.log(
      'Upload returned no digest; the staged script was not re-verified',
      name: 'seance.inbox',
      level: 900,
    );
  }
  if (uploaded != null && uploaded.toLowerCase() != digest) {
    throw const InboxStagingException(
      'The uploaded script does not match the one you reviewed.',
    );
  }
  // `preserveMode` only applies to a newly created file on some servers, so
  // the mode is set explicitly too.
  await fs.setMode(path, _kScriptMode);

  final quoted = quoteShellWord(path);
  final commandLine =
      proposal.script.startsWith('#!') ? quoted : 'sh $quoted';
  return StagedScript(path: path, commandLine: commandLine, sha256Hex: digest);
}

Future<void> _ensureDirectory(RemoteFileSystem fs, String path) async {
  try {
    final entry = await fs.stat(path, followLinks: false);
    if (entry.type != RemoteFileType.directory) {
      throw InboxStagingException(
        '$path exists and is not a directory, so the script cannot be '
        'staged there.',
      );
    }
    return;
  } on RemoteFileException catch (error) {
    if (error.kind != RemoteFileErrorKind.notFound) rethrow;
  }
  await fs.createDirectory(path);
  await fs.setMode(path, _kDirectoryMode);
}
