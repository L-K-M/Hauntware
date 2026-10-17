import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'apk_installer.dart';

/// A release APK: where to fetch it and the exact bytes it must be.
@immutable
class ApkRelease {
  const ApkRelease({
    required this.url,
    required this.size,
    required this.sha256,
  });

  final Uri url;

  /// The size in bytes the release publishes.
  final int size;

  /// The published SHA-256 digest as lower-case hex.
  final String sha256;

  @override
  bool operator ==(Object other) =>
      other is ApkRelease &&
      other.url == url &&
      other.size == size &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(url, size, sha256);
}

/// What the update is doing, for the app's banner or alert row.
sealed class ApkUpdateState {
  const ApkUpdateState();
}

/// Nothing downloaded or in flight.
final class ApkUpdateIdle extends ApkUpdateState {
  const ApkUpdateIdle();
}

/// The APK is downloading: [received] of [total] bytes.
final class ApkUpdateDownloading extends ApkUpdateState {
  const ApkUpdateDownloading(this.received, this.total);

  final int received;
  final int total;

  double get fraction => total == 0 ? 0 : received / total;
}

/// The verified APK went to the system installer, which owns the rest:
/// installing replaces and restarts the app. If the user backs out,
/// [ApkUpdater.update] reopens the installer without downloading again.
final class ApkUpdateReady extends ApkUpdateState {
  const ApkUpdateReady();
}

/// The last attempt failed; [ApkUpdater.update] tries again.
final class ApkUpdateFailed extends ApkUpdateState {
  const ApkUpdateFailed(this.failure);

  final ApkUpdateFailure failure;
}

enum ApkUpdateFailure {
  /// Offline, timed out, or the server refused the download.
  download,

  /// The file did not match the published size or SHA-256 digest, so it
  /// was discarded unopened.
  verification,

  /// Android could not open the installer or refused the file.
  installer,
}

/// Downloads a release APK the user chose to install, proves it against
/// the release's published size and digest, and opens the system
/// installer. Android only: the apps construct one there and nowhere else.
///
///   idle ──update──▶ downloading ──verified──▶ ready (installer open)
///    ▲                  │      │                   │
///    └──────cancel──────┘      └──fails──▶ failed ◀┘ installer refused
///
/// From ready or failed, [update] tries again and reuses a verified
/// file. The download is the only network call and happens only there.
class ApkUpdater extends ChangeNotifier {
  ApkUpdater({
    http.Client? client,
    this._installer = const ApkInstaller(),
    this._timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// The one staged file; a newer download replaces it by rename.
  static const _stagedName = 'update.apk';

  final http.Client _client;
  final bool _ownsClient;
  final ApkInstaller _installer;

  /// Applies to the response headers and to every gap between chunks,
  /// not to the whole download, which may take minutes on a phone.
  final Duration _timeout;

  ApkUpdateState _state = const ApkUpdateIdle();
  Completer<void>? _abort;
  ({ApkRelease release, File file})? _staged;
  bool _disposed = false;

  ApkUpdateState get state => _state;

  /// Downloads [release], verifies it and opens the installer. Does
  /// nothing while a download runs. Once [release] is verified, this
  /// reopens the installer instead of downloading it again.
  Future<void> update(ApkRelease release) async {
    if (_state is ApkUpdateDownloading) return;

    final staged = _staged;
    if (staged != null &&
        staged.release == release &&
        await staged.file.exists()) {
      await _install(staged.file);
      return;
    }

    final File apk;
    try {
      apk = await _download(release);
    } on http.RequestAbortedException {
      _set(const ApkUpdateIdle());
      return;
    } on _VerificationFailed {
      _set(const ApkUpdateFailed(ApkUpdateFailure.verification));
      return;
    } on Exception {
      // Offline, refused, timed out, no staging directory or no space.
      _set(const ApkUpdateFailed(ApkUpdateFailure.download));
      return;
    }

    _staged = (release: release, file: apk);
    await _install(apk);
  }

  /// Stops a running download and discards what arrived.
  void cancel() {
    final abort = _abort;
    if (abort == null || abort.isCompleted) return;
    abort.complete();
  }

  Future<File> _download(ApkRelease release) async {
    // Armed before the first await so a Cancel tapped at once still lands.
    final abort = Completer<void>();
    _abort = abort;
    _set(ApkUpdateDownloading(0, release.size));

    File? partial;
    try {
      final directory = await _installer.stagingDirectory();
      final apk = File('$directory/$_stagedName');
      partial = File('${apk.path}.part');

      final request = http.AbortableRequest(
        'GET',
        release.url,
        abortTrigger: abort.future,
      );
      final response = await _client.send(request).timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw const _DownloadRefused();
      }

      // Hash while writing, so the file is read once and an oversized
      // body stops at the first byte past the published size.
      final digest = _DigestSink();
      final hash = sha256.startChunkedConversion(digest);
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(_timeout)) {
          // A client without abort support still stops at the next chunk.
          if (abort.isCompleted) {
            throw http.RequestAbortedException(release.url);
          }

          received += chunk.length;
          if (received > release.size) throw const _VerificationFailed();

          hash.add(chunk);
          sink.add(chunk);
          _progress(received, release.size);
        }
      } finally {
        await sink.close();
      }
      hash.close();

      if (received != release.size ||
          digest.value.toString() != release.sha256) {
        throw const _VerificationFailed();
      }
      return await partial.rename(apk.path);
    } catch (_) {
      // A timed-out request is still open; aborting releases it.
      if (!abort.isCompleted) abort.complete();
      await _deleteQuietly(partial);
      rethrow;
    } finally {
      _abort = null;
    }
  }

  Future<void> _install(File apk) async {
    try {
      await _installer.install(apk.path);
      _set(const ApkUpdateReady());
    } on PlatformException {
      _set(const ApkUpdateFailed(ApkUpdateFailure.installer));
    }
  }

  /// Notifies once per whole percent: a 100 MB download arrives in
  /// thousands of chunks, and every notification rebuilds the row.
  void _progress(int received, int total) {
    final previous = _state;
    if (previous is ApkUpdateDownloading &&
        received < total &&
        _percent(previous.received, total) == _percent(received, total)) {
      return;
    }
    _set(ApkUpdateDownloading(received, total));
  }

  static int _percent(int received, int total) =>
      total == 0 ? 0 : received * 100 ~/ total;

  void _set(ApkUpdateState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  static Future<void> _deleteQuietly(File? file) async {
    if (file == null) return;
    try {
      await file.delete();
    } on FileSystemException {
      // Never created, or already gone.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

/// The server answered, but not with the file.
class _DownloadRefused implements Exception {
  const _DownloadRefused();
}

class _VerificationFailed implements Exception {
  const _VerificationFailed();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
