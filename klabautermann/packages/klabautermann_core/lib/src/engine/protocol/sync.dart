import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'sampling.dart' show CadenceProfile;

/// A pulled `hostkey:` record whose key differs from the pin this device
/// trusts for the same `host:port` (03 §4.9). Re-derived on every round, so
/// a dismissed warning re-arms until the user resolves it.
final class SyncPinConflict {
  const SyncPinConflict({
    required this.locator,
    required this.localFingerprintSha256,
    required this.pulledFingerprintSha256,
  });

  /// `host:port` — the locator spelling a pin's record id carries.
  final String locator;

  /// The fingerprint of the pin this device trusts.
  final String localFingerprintSha256;

  /// The fingerprint the winning `hostkey:` record carries.
  final String pulledFingerprintSha256;

  @override
  bool operator ==(Object other) =>
      other is SyncPinConflict &&
      other.locator == locator &&
      other.localFingerprintSha256 == localFingerprintSha256 &&
      other.pulledFingerprintSha256 == pulledFingerprintSha256;

  @override
  int get hashCode =>
      Object.hash(locator, localFingerprintSha256, pulledFingerprintSha256);
}

/// The account budget of the `klabautermann:` records (03 §4.8): at most
/// [kSyncPrefixBudgetBytes] of sealed blobs, with a warning from
/// [kSyncPrefixWarnFraction] of it (SYN-09's account size view).
@immutable
final class SyncPrefixBudget {
  const SyncPrefixBudget(this.usedBytes, {this.byPrefix = const {}});

  /// The sealed blobs of every live `klabautermann:` record the account
  /// holds, as this device last pulled them.
  final int usedBytes;

  /// Every live record the account holds, as this device last pulled it,
  /// grouped by its id's prefix ([syncRecordPrefixOf]): the account size
  /// view's rows (SYN-09).
  final Map<String, SyncRecordUsage> byPrefix;

  /// Whether the records take [kSyncPrefixWarnFraction] of the budget or
  /// more.
  bool get warns =>
      usedBytes >= kSyncPrefixBudgetBytes * kSyncPrefixWarnFraction;

  /// Whether the records take the whole budget or more.
  bool get full => usedBytes >= kSyncPrefixBudgetBytes;
}

/// How many live records of one id prefix the account holds and how many
/// bytes their sealed blobs take (SYN-09).
@immutable
final class SyncRecordUsage {
  const SyncRecordUsage({required this.records, required this.bytes});

  final int records;
  final int bytes;

  @override
  bool operator ==(Object other) =>
      other is SyncRecordUsage &&
      other.records == records &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(records, bytes);
}

/// The prefix the account size view groups a record [id] under (SYN-09):
/// a `klabautermann:` record's type with the prefix
/// (`klabautermann:pref`), any other record's first segment (`snippet`),
/// or the whole id when it has no `:`, or is `klabautermann:` and a type
/// with no further `:`.
String syncRecordPrefixOf(String id) {
  final first = id.indexOf(':');
  if (first < 0) return id;
  if (id.substring(0, first) != 'klabautermann') return id.substring(0, first);
  final second = id.indexOf(':', first + 1);
  return second < 0 ? id : id.substring(0, second);
}

/// The `klabautermann:` prefix's account budget [E] (03 §4.8).
const int kSyncPrefixBudgetBytes = 1024 * 1024;

/// The share of [kSyncPrefixBudgetBytes] from which the budget warns [E]
/// (03 §4.8).
const double kSyncPrefixWarnFraction = 0.8;

/// One server's synced preferences, its `pref` record (03 §4.8, SYN-04).
/// Every field defaults to what a server without a record has.
@immutable
final class ServerPrefs {
  const ServerPrefs({
    this.readOnly = false,
    this.cadence,
    this.pinnedUnits = const [],
    this.pinnedContainers = const [],
    this.marks = const {},
    this.panelOrder = const [],
    this.hostAuditLine = true,
    this.stackScanDirs = const [],
  });

  /// The server's own read-only switch (SAF-06).
  final bool readOnly;

  /// The cadence preset chosen for the server; null leaves the device's.
  final CadenceProfile? cadence;

  /// Units and containers pinned to the top of their lists, by name.
  final List<String> pinnedUnits, pinnedContainers;

  /// Targets the user marked protected (SAF-22): unit, container and
  /// stack names.
  final Set<String> marks;

  /// The server's panels in the user's order, by name; a panel it does
  /// not name keeps its place after them.
  final List<String> panelOrder;

  /// Whether a run writes its syslog line on the host (SAF-13).
  final bool hostAuditLine;

  /// Absolute directories the stack scan looks in (STK-01).
  final List<String> stackScanDirs;

  /// These preferences with the safety fields replaced (M5 plan M06,
  /// M19).
  ServerPrefs copyWith({
    bool? readOnly,
    Set<String>? marks,
    bool? hostAuditLine,
  }) => ServerPrefs(
    readOnly: readOnly ?? this.readOnly,
    cadence: cadence,
    pinnedUnits: pinnedUnits,
    pinnedContainers: pinnedContainers,
    marks: marks ?? this.marks,
    panelOrder: panelOrder,
    hostAuditLine: hostAuditLine ?? this.hostAuditLine,
    stackScanDirs: stackScanDirs,
  );
}

/// The sync round's phase behind [SyncStatus] (03 §10.1).
enum SyncPhase { idle, running, succeeded, failed }

/// The request a [SyncStatus] answers.
enum SyncOperation {
  /// [EnrollSync].
  enroll,

  /// [RunSyncRound].
  round,

  /// [SignOutSync].
  signOut,
}

/// Why a sync operation failed (03 §4.3, §4.5).
enum SyncFailure {
  /// This process does not hold the support directory alone (03 §4.10,
  /// D63): the instance lock could not be taken, so the engine signs in
  /// and syncs nothing.
  directoryShared,

  /// `settings.json` gave no device id this session, so no record could
  /// carry this install's authorship.
  noDeviceId,

  /// A round or sign-out was asked for, but this device is not enrolled.
  notEnrolled,

  /// The device is enrolled in another account; sign out first.
  otherAccount,

  /// The server address, account name, password or passphrase is not
  /// one the engine can send (`validateSyncEnrollment`).
  invalidRequest,

  /// The server offered weaker key derivation than the suite accepts, so
  /// no key was derived (03 §4.5).
  kdfDowngrade,

  /// The server refused the account name and password.
  credentialsRejected,

  /// The server refused the stored session: the account was deleted or
  /// signed out elsewhere.
  sessionRejected,

  /// The server could not be reached or did not answer in time.
  unreachable,

  /// The server answered with an error of its own.
  serverError,

  /// The sync account is at its storage quota: the server refused records
  /// that would grow it. Edits and deletions that fit were stored; the
  /// refused records stay on this device and are offered again each round
  /// ([SyncStatus.recordsAwaitingSpace], zero from a server that refuses a
  /// whole push instead).
  accountFull,

  /// The OS keystore could not store or hand over the session token or
  /// the vault key.
  keystoreUnavailable,

  /// A sync state file is left as it is this session, so the operation's
  /// state could not be saved.
  storeUnavailable,

  /// Anything else; [SyncStatus.detail] says what.
  other,
}

/// The enrolled sync account as the app shows it: never a secret.
@immutable
final class SyncAccountInfo {
  const SyncAccountInfo({required this.baseUrl, required this.username});

  final String baseUrl;
  final String username;

  @override
  bool operator ==(Object other) =>
      other is SyncAccountInfo &&
      baseUrl == other.baseUrl &&
      username == other.username;

  @override
  int get hashCode => Object.hash(baseUrl, username);
}

/// What went wrong with a sync state file when the engine opened it (03
/// §4.10, D62).
enum SyncStoreIssueKind {
  /// It was damaged and renamed to [SyncStoreIssue.preservedAs]; the store
  /// started empty.
  recovered,

  /// It could not be read, or was damaged and could not be renamed. It is
  /// left as it is and nothing is saved to it this session.
  leftAsIs,

  /// A newer build wrote it. It is left as it is and nothing is saved to
  /// it this session.
  newerVersion,
}

/// One sync state file's problem at start, carried by [EngineReady].
@immutable
final class SyncStoreIssue {
  const SyncStoreIssue(
    this.fileName,
    this.kind, {
    this.preservedAs,
    this.detail,
  });

  /// The file's name in the support directory, such as
  /// `sync_enrollment.json`.
  final String fileName;
  final SyncStoreIssueKind kind;

  /// The damaged file's new path; set for [SyncStoreIssueKind.recovered]
  /// only.
  final String? preservedAs;

  /// The failure behind [kind], for diagnostics only.
  final String? detail;
}

/// One OS-keystore call a [KeystoreRequest] carries: the engine's
/// `SyncKeystore` port, which the app forwards to `ghost_keystore`'s
/// `MasterKeyManager` under Klabautermann's entry names (03 §4.5, D62).
@immutable
sealed class KeystoreOperation {
  const KeystoreOperation();
}

/// Store [value] under the API-key [name]; answered [KeystoreDone].
final class KeystorePutApiKey extends KeystoreOperation {
  const KeystorePutApiKey(this.name, this.value);

  final String name;
  final String value;
}

/// Read the API-key [name]; answered [KeystoreApiKey].
final class KeystoreGetApiKey extends KeystoreOperation {
  const KeystoreGetApiKey(this.name);

  final String name;
}

/// Forget the API-key [name]; answered [KeystoreDone].
final class KeystoreDeleteApiKey extends KeystoreOperation {
  const KeystoreDeleteApiKey(this.name);

  final String name;
}

/// Read the vault master key without minting one; answered
/// [KeystoreMasterKey].
final class KeystoreReadMasterKey extends KeystoreOperation {
  const KeystoreReadMasterKey();
}

/// Replace the vault master key with [key]; answered [KeystoreDone].
final class KeystoreWriteMasterKey extends KeystoreOperation {
  const KeystoreWriteMasterKey(this.key);

  final Uint8List key;
}

/// The app's answer to a [KeystoreOperation].
@immutable
sealed class KeystoreResult {
  const KeystoreResult();
}

/// A write or delete finished.
final class KeystoreDone extends KeystoreResult {
  const KeystoreDone();
}

/// An API key's value, or null when there is none or the keystore cannot
/// answer.
final class KeystoreApiKey extends KeystoreResult {
  const KeystoreApiKey(this.value);

  final String? value;
}

/// The vault master key, or null when there is none or the keystore cannot
/// answer.
final class KeystoreMasterKey extends KeystoreResult {
  const KeystoreMasterKey(this.key);

  final Uint8List? key;
}

/// The keystore refused the operation; [detail] says why, for diagnostics.
final class KeystoreRefused extends KeystoreResult {
  const KeystoreRefused(this.detail);

  final String detail;
}
