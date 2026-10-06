import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

import 'external_file_opener.dart';

/// Runs a program without a shell, like [Process.run].
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Mark-of-the-Web: zone 3 is the internet zone. The server's address is
/// left out on purpose, so it does not travel with copies of the file.
const _zoneIdentifierStream = ':Zone.Identifier';
const _zoneIdentifier = '[ZoneTransfer]\r\nZoneId=3\r\n';

const _xattr = '/usr/bin/xattr';
const _quarantineAttribute = 'com.apple.quarantine';

/// The flags non-Safari downloaders write: quarantined, internet origin.
const _quarantineFlags = '0081';

/// Marks files Séance writes from a server the way browsers mark downloads,
/// so the OS treats them as untrusted when they are opened (finding P1-03a):
/// Mark-of-the-Web on Windows, a quarantine attribute on macOS. Linux has no
/// equivalent. Best effort: a volume without alternate data streams or
/// extended attributes must not stop an open, so failures are only logged.
class DownloadProvenance {
  /// Marks for the platform Séance runs on.
  DownloadProvenance() : this.forHost(currentEditorHostPlatform);

  /// Marks as [host] would; [runProcess] stands in for [Process.run].
  @visibleForTesting
  DownloadProvenance.forHost(this._host, {this._runProcess = Process.run});

  final EditorHostPlatform? _host;
  final ProcessRunner _runProcess;

  Future<void> markDownloaded(String path) async {
    try {
      switch (_host) {
        case EditorHostPlatform.windows:
          await File(
            '$path$_zoneIdentifierStream',
          ).writeAsString(_zoneIdentifier, flush: true);
        case EditorHostPlatform.macos:
          await _quarantine(path);
        case EditorHostPlatform.linux:
        case null:
          return;
      }
    } catch (error, stackTrace) {
      developer.log(
        'Could not mark a downloaded file as untrusted',
        name: 'seance.app',
        level: 900,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// `0081;<seconds since 1970, hex>;<agent>;<event id>`, e.g.
  /// `0081;6704a1c3;Seance;6F9619FF-8B86-D011-B42D-00C04FC964FF`. Written
  /// as hex (`-wx`) so the attribute holds exactly these bytes, and with
  /// the ASCII product name the bundle itself uses.
  Future<void> _quarantine(String path) async {
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final value = [
      _quarantineFlags,
      seconds.toRadixString(16),
      'Seance',
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
