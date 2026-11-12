import 'dart:developer' as developer;
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:seance_protocol/seance_protocol.dart';

/// Runs a program without a shell, like [Process.run].
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// The desktop platform a [DownloadProvenance] marks for; [unsupported]
/// covers hosts with no download mark (mobile).
enum ProvenancePlatform { macos, windows, linux, unsupported }

/// Mark-of-the-Web: zone 3 is the internet zone. The server's address is
/// left out on purpose, so it does not travel with copies of the file.
const _zoneIdentifierStream = ':Zone.Identifier';
const _zoneIdentifier = '[ZoneTransfer]\r\nZoneId=3\r\n';

const _xattr = '/usr/bin/xattr';
const _quarantineAttribute = 'com.apple.quarantine';

/// The flags non-Safari downloaders write: quarantined, internet origin.
const _quarantineFlags = '0081';

ProvenancePlatform get _currentProvenancePlatform {
  if (Platform.isMacOS) return ProvenancePlatform.macos;
  if (Platform.isWindows) return ProvenancePlatform.windows;
  if (Platform.isLinux) return ProvenancePlatform.linux;
  return ProvenancePlatform.unsupported;
}

/// Marks files an app writes from a server the way browsers mark downloads,
/// so the OS treats them as untrusted when they are opened (finding P1-03a):
/// Mark-of-the-Web on Windows, a quarantine attribute on macOS. Linux has no
/// equivalent. Best effort: a volume without alternate data streams or
/// extended attributes must not stop an open, so failures are only logged.
class DownloadProvenance {
  /// Marks for the platform this host runs on; [agent] is the product name
  /// written into the quarantine attribute's agent field.
  DownloadProvenance({required String agent})
    : this.forHost(_currentProvenancePlatform, agent: agent);

  /// Marks as [host] would; [runProcess] stands in for [Process.run].
  @visibleForTesting
  DownloadProvenance.forHost(
    this._host, {
    required this._agent,
    this._runProcess = Process.run,
  });

  final ProvenancePlatform _host;
  final String _agent;
  final ProcessRunner _runProcess;

  Future<void> markDownloaded(String path) async {
    try {
      switch (_host) {
        case ProvenancePlatform.windows:
          await File(
            '$path$_zoneIdentifierStream',
          ).writeAsString(_zoneIdentifier, flush: true);
        case ProvenancePlatform.macos:
          await _quarantine(path);
        case ProvenancePlatform.linux:
        case ProvenancePlatform.unsupported:
          return;
      }
    } catch (error, stackTrace) {
      developer.log(
        'Could not mark a downloaded file as untrusted',
        name: '${_agent.toLowerCase()}.app',
        level: 900,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// `0081;<seconds since 1970, hex>;<agent>;<event id>`, e.g.
  /// `0081;6704a1c3;Seance;3f2a9c01-7b4e-4d8a-9c1b-2e5f6a7b8c9d`. Written
  /// as hex (`-wx`) so the attribute holds exactly these bytes, and with
  /// the ASCII product name the bundle itself uses.
  Future<void> _quarantine(String path) async {
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final value = [
      _quarantineFlags,
      seconds.toRadixString(16),
      _agent,
      uuidV4(),
    ].join(';');
    final hex = value.codeUnits
        .map((unit) => unit.toRadixString(16).padLeft(2, '0'))
        .join();
    final arguments = ['-wx', _quarantineAttribute, hex, path];
    final result = await _runProcess(_xattr, arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        _xattr,
        arguments,
        '${result.stderr}',
        result.exitCode,
      );
    }
  }
}
