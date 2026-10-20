// Reads an edit's target (03 §8.5, SAF-12, X-05): the content the editor
// opens, its SHA-256, which the edit's compare-and-swap names, and who
// owns it, which decides whether the write needs admin mode. A file the
// login user cannot read is read through admin mode's elevation when it
// is on; another account's crontab always is.
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        EditCommands,
        HostCommandError,
        HostCommands,
        HostProfile,
        parseReadHeader;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandResult, SshLink, quoteShellWord;

import '../admin/admin_mode.dart' show AdminSession;
import '../engine/protocol.dart';

/// What an edit's read and plan see of one server: its ready link, its
/// probe, and admin mode's session, null while admin mode is off.
typedef EditContext = ({
  SshLink link,
  HostProfile profile,
  AdminSession? admin,
});

/// The most an edit reads of a file: below `SshLink.run`'s 256 KiB
/// output cap, which the elevation prelude's runs keep, with room for the
/// header line.
const int kEditReadCap = 240 * 1024;

/// Reads [target] for an edit; never throws.
Future<EditReadResult> readEditable(EditTarget target, EditContext c) async {
  try {
    return switch (target) {
      FileTarget(:final path) => await _readFile(path, c),
      CrontabTarget(:final user) => await _readCrontab(user, c),
    };
  } on HostCommandError {
    return const EditReadFailed(EditReadFailure.invalidTarget);
  } on Object catch (error) {
    // A refused channel, a closed link, a timeout or a refused elevation.
    return EditReadFailed(EditReadFailure.failed, detail: '$error');
  }
}

Future<EditReadResult> _readFile(String path, EditContext c) async {
  final argv = EditCommands.readFile(path, cap: kEditReadCap);
  final result = await _runMaybeElevated(argv, c);
  if (result == null) {
    return const EditReadFailed(EditReadFailure.adminRequired);
  }
  if (result.exitCode != 0) {
    return EditReadFailed(
      _missing.hasMatch(result.stderr)
          ? EditReadFailure.notFound
          : _denied.hasMatch(result.stderr)
          ? EditReadFailure.adminRequired
          : EditReadFailure.failed,
      detail: result.stderr.trim(),
    );
  }

  final out = result.stdout;
  final newline = out.indexOf('\n');
  final header = parseReadHeader(newline < 0 ? out : out.substring(0, newline));
  if (header == null) {
    return const EditReadFailed(EditReadFailure.failed);
  }
  if (header.size > kEditReadCap) {
    return const EditReadFailed(EditReadFailure.tooLarge);
  }
  final text = newline < 0 ? '' : out.substring(newline + 1);
  // Bytes that are not UTF-8 decode to U+FFFD and hash differently from
  // the file, as does a file that changed between stat and cat.
  if (text.contains('\u0000') || _sha256Of(text) != header.sha256) {
    return const EditReadFailed(EditReadFailure.notText);
  }
  return EditContent(
    text: text,
    sha256: header.sha256,
    privileged: header.uid != c.profile.uid,
    uid: header.uid,
    gid: header.gid,
    mode: header.mode,
  );
}

Future<EditReadResult> _readCrontab(String? user, EditContext c) async {
  final own = user == null || user == c.profile.user;
  final RemoteCommandResult result;
  if (own) {
    result = await _run(c.link, const ['crontab', '-l']);
  } else {
    final admin = c.admin;
    if (admin == null) {
      return const EditReadFailed(EditReadFailure.adminRequired);
    }
    result = await admin.executor.run(
      HostCommands.crontabList(user),
      password: admin.password,
    );
  }
  // `crontab -l` exits 1 with "no crontab for <user>" when there is none,
  // which reads as an empty table (03 §7.7).
  final String text;
  if (result.exitCode == 0) {
    text = result.stdout;
  } else if (_noCrontab.hasMatch(result.stderr)) {
    text = '';
  } else {
    return EditReadFailed(
      _denied.hasMatch(result.stderr)
          ? EditReadFailure.adminRequired
          : EditReadFailure.failed,
      detail: result.stderr.trim(),
    );
  }
  return EditContent(text: text, sha256: _sha256Of(text), privileged: !own);
}

/// Runs [argv] as the login user, and again through admin mode when the
/// host refused it for want of rights; null when it needs admin mode and
/// admin mode is off.
Future<RemoteCommandResult?> _runMaybeElevated(
  List<String> argv,
  EditContext c,
) async {
  final plain = await _run(c.link, argv);
  if (plain.exitCode == 0 || !_denied.hasMatch(plain.stderr)) return plain;
  final admin = c.admin;
  if (admin == null) return null;
  return admin.executor.run(argv, password: admin.password);
}

Future<RemoteCommandResult> _run(SshLink link, List<String> argv) => link.run(
  HostCommands.commandLine(argv, quote: quoteShellWord),
  stdin: const [],
);

String _sha256Of(String text) => sha256.convert(utf8.encode(text)).toString();

final _denied = RegExp('Permission denied', caseSensitive: false);
final _missing = RegExp('No such file', caseSensitive: false);
final _noCrontab = RegExp('no crontab for', caseSensitive: false);
