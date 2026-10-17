/// The engine's durable enrollment state (03 §4.10, D62): the catalog
/// library's `SyncEnrollmentState` seam over a file of its own under the
/// support directory, never the record store, whose corruption quarantine
/// restarts it empty and must not erase the push hold. The device id is
/// not in it: `settings.json` holds it (`klabautermann.sync.deviceId`),
/// and the store is handed it.
library;

import 'dart:async';
import 'dart:io';

import 'package:seance_core/catalog.dart'
    show SyncAccount, SyncAccountMode, SyncEnrollmentState;

import '../settings/device_settings_store.dart' show writeFileAtomically;
import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import 'sync_state_file.dart';

/// The enrollment state file under the support directory (03 §4.10).
const String syncEnrollmentFileName = 'sync_enrollment.json';

const String _passphraseUnverifiedKey = 'passphraseUnverified';
const String _noticesKey = 'notices';
const String _accountKey = 'account';
const String _baseUrlKey = 'baseUrl';
const String _usernameKey = 'username';
const String _modeKey = 'mode';

/// `sync_enrollment.json`: `{"version": 1, "passphraseUnverified": bool,
/// "notices": [notice keys], "account": {"baseUrl", "username", "mode"}}`,
/// the notices sorted and the account left out before enrollment. It holds
/// no secret: the session token and the vault key live only in the OS
/// keystore (`SyncCredentialStore`, 03 §4.5).
///
/// Kept like the verdict files: the engine owns one instance, a change
/// applies in memory first and is written in order, and a failed write is
/// thrown to the caller. A damaged file is renamed aside and the store
/// starts empty, so the install reads as not enrolled: no round runs
/// without an account, so the lost push hold holds nothing back, and the
/// next enrollment sets the flag again. See [SyncStateFile].
final class FileSyncEnrollmentState implements SyncEnrollmentState {
  FileSyncEnrollmentState._(
    this._file,
    this._deviceId,
    this._unverified,
    this._notices,
    this._account,
  );

  final SyncStateFile _file;
  final String _deviceId;
  bool _unverified;
  final Set<String> _notices;
  SyncAccount? _account;

  /// Opens `sync_enrollment.json` in [supportDirectory]. A file it cannot
  /// use leaves the store empty and is reported in [issue]; the only throw
  /// is an [ArgumentError] for an empty [deviceId]. [deviceId] is the install's id from `settings.json`
  /// (`DeviceSettingsStore.deviceId`), which this store only hands out:
  /// the settings store minted it once, and no enrollment may run without
  /// one. [writer] and [now] are seams for tests.
  static Future<FileSyncEnrollmentState> open(
    Directory supportDirectory, {
    required String deviceId,
    required SupportDirectoryAccess access,
    SyncStateWriter writer = writeFileAtomically,
    DateTime Function() now = DateTime.now,
  }) async {
    if (deviceId.isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must not be empty');
    }
    final (file, body) = await SyncStateFile.open(
      File(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '$syncEnrollmentFileName',
      ),
      access: access,
      decode: _decode,
      writer: writer,
      now: now,
    );
    return FileSyncEnrollmentState._(
      file,
      deviceId,
      body?.unverified ?? false,
      body?.notices ?? {},
      body?.account,
    );
  }

  /// The problem met while opening, or null when the file was fine or
  /// absent.
  SyncStateIssue? get issue => _file.issue;

  /// The id `settings.json` holds, never minted here (03 §4.10).
  @override
  Future<String> deviceId() async => _deviceId;

  @override
  Future<bool> passphraseUnverified() async => _unverified;

  @override
  Future<void> setPassphraseUnverified(bool value) {
    if (_unverified == value && !_file.hasUnsavedChanges) {
      return Future.value();
    }
    _unverified = value;
    return _save();
  }

  @override
  Future<Set<String>> notices() async => Set.of(_notices);

  @override
  Future<void> setNotice(String notice, bool active) {
    final changed = active ? _notices.add(notice) : _notices.remove(notice);
    return changed || _file.hasUnsavedChanges ? _save() : Future.value();
  }

  @override
  Future<SyncAccount?> account() async => _account;

  @override
  Future<void> setAccount(SyncAccount? account) {
    if (_sameAccount(_account, account) && !_file.hasUnsavedChanges) {
      return Future.value();
    }
    _account = account;
    return _save();
  }

  static bool _sameAccount(SyncAccount? a, SyncAccount? b) =>
      a?.baseUrl == b?.baseUrl &&
      a?.username == b?.username &&
      a?.mode == b?.mode;

  Future<void> _save() {
    final account = _account;
    return _file.save({
      _passphraseUnverifiedKey: _unverified,
      _noticesKey: _notices.toList()..sort(),
      if (account != null)
        _accountKey: {
          _baseUrlKey: account.baseUrl,
          _usernameKey: account.username,
          _modeKey: account.mode.name,
        },
    });
  }

  /// The body's state, or a [FormatException] for any field this build
  /// cannot use, an unknown account mode included: a guess at the account
  /// would point rounds at the wrong server or posture.
  static ({bool unverified, Set<String> notices, SyncAccount? account}) _decode(
    Map<String, Object?> body,
  ) {
    final unverified = switch (body[_passphraseUnverifiedKey]) {
      null => false,
      final bool value => value,
      _ => throw const FormatException('passphraseUnverified is not a bool'),
    };

    final SyncAccount? account;
    switch (body[_accountKey]) {
      case null:
        account = null;
      case {
            _baseUrlKey: final String baseUrl,
            _usernameKey: final String username,
            _modeKey: final String mode,
          }
          when baseUrl.isNotEmpty && username.isNotEmpty:
        final parsed = SyncAccountMode.values.asNameMap()[mode];
        if (parsed == null) {
          throw FormatException('account has an unknown mode: $mode');
        }
        account = SyncAccount(
          baseUrl: baseUrl,
          username: username,
          mode: parsed,
        );
      default:
        throw const FormatException('account is not a usable account');
    }

    return (
      unverified: unverified,
      notices: decodeStringList(body, _noticesKey).toSet(),
      account: account,
    );
  }
}
