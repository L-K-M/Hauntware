import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/catalog.dart' show syncLocalDirectory;
import 'package:seance_core/seance_core.dart'
    show
        CredentialDraft,
        CredentialSource,
        IdentityAuditLog,
        IdentityReadEvent,
        Secret,
        ServerConfig,
        expandHomePath,
        restrictFileToOwner,
        uuidV4;

/// The identity-read audit log's file in the support directory (03 §4.10),
/// the name Séance and Poltergeist give theirs.
const String identityAuditLogFileName = 'identity_reads.jsonl';

/// The largest key file the engine reads. A private key file takes a few
/// KiB, tens for the largest RSA keys; the bound keeps a path such as
/// `/dev/zero` from filling the engine isolate's memory.
const int _maxIdentityFileBytes = 1024 * 1024;

/// How long a connect waits for its audit record before going on without
/// it [E]: the trail must not hold up, or fail, a connect.
const Duration _auditTimeout = Duration(seconds: 2);

/// The variable `flatpak run` always sets inside the sandbox
/// (`flatpak_run_apply_env_prompt` in flatpak's `common/flatpak-run.c`).
const String _flatpakIdVariable = 'FLATPAK_ID';

/// Why an identity file could not be read.
enum IdentityFileFailure {
  /// No file at the path.
  notFound,

  /// The operating system refused the read.
  accessDenied,

  /// The file was missing inside the Flatpak sandbox, which shows only
  /// the paths it grants (Klabautermann's manifest grants only
  /// `~/.ssh/config`, 04 §12.1): a key outside them reads as missing
  /// whether or not it exists. The remedy is a wider grant (K46), not
  /// another path. A file the sandbox shows but whose mode or owner
  /// refuses the read stays [accessDenied].
  sandboxDenied,

  /// The path is not a regular file of UTF-8 text within the size bound,
  /// for example a directory, a FIFO or a device.
  unreadable,
}

/// The engine could not read [path], the expanded `IdentityFile` of
/// [serverId] (a fleet server or a jump hop). Stays in the engine: the app
/// words [failure], never [cause].
final class IdentityFileUnavailable implements Exception {
  const IdentityFileUnavailable({
    required this.serverId,
    required this.path,
    required this.failure,
    required this.cause,
  });

  final String serverId;
  final String path;
  final IdentityFileFailure failure;

  /// The I/O or decoding error behind [failure], for logs.
  final Object cause;

  @override
  String toString() =>
      'Identity file $path of $serverId unavailable (${failure.name}): '
      '$cause';
}

/// The engine's [CredentialSource] for `seance_core`'s
/// `CredentialResolver` (03 §4.5). Agent auth never reaches it: the
/// resolver answers that itself, and the agent signs through
/// `SshAgentClient` when the link connects. A key file is read at connect
/// time from its expanded path ("reference, don't store"), and every
/// attempt is recorded in the audit log. Vault entries are read through
/// [vault], `EngineVault.read`.
final class EngineCredentialSource implements CredentialSource {
  /// [vault] reads a vault entry; without one no entry is ever found.
  /// [environment] and [isMacOS] default to the running process's; tests
  /// pass their own.
  EngineCredentialSource(
    this._audit, {
    this._vault,
    Map<String, String>? environment,
    bool? isMacOS,
  }) : _environment = environment ?? Platform.environment,
       _isMacOS = isMacOS ?? Platform.isMacOS;

  final IdentityAuditLog _audit;
  final Future<Secret?> Function(String secretRef)? _vault;
  final Map<String, String> _environment;
  final bool _isMacOS;

  /// Throws `VaultUnavailableException` when a vault exists that the
  /// keystore cannot open.
  @override
  Future<Secret?> storedSecret(String secretRef) async =>
      _vault == null ? null : await _vault(secretRef);

  /// Reads [config]'s key file. [draft] is ignored: the engine has no
  /// editor drafts or bookmark grants. Throws [IdentityFileUnavailable].
  @override
  Future<String> identityFile(
    ServerConfig config,
    CredentialDraft? draft,
  ) async {
    // `~` means the real home even when a macOS sandbox points HOME at its
    // container; the macOS build carries no sandbox entitlement today.
    final path = expandHomePath(
      config.identityFilePath!,
      environment: _environment,
      isMacOS: _isMacOS,
    );

    final String pem;
    try {
      pem = await _readBounded(path);
    } on Exception catch (error, stackTrace) {
      // Failed reads are audited too; recording never throws, so it
      // cannot replace this error.
      await _record(config, path, error: error);
      Error.throwWithStackTrace(
        IdentityFileUnavailable(
          serverId: config.id,
          path: path,
          failure: _classify(error),
          cause: error,
        ),
        stackTrace,
      );
    }

    await _record(config, path);
    return pem;
  }

  IdentityFileFailure _classify(Exception error) {
    final failure = switch (error) {
      PathNotFoundException() => IdentityFileFailure.notFound,
      PathAccessException() => IdentityFileFailure.accessDenied,
      _ => IdentityFileFailure.unreadable,
    };
    final inFlatpak = (_environment[_flatpakIdVariable] ?? '').isNotEmpty;
    return inFlatpak && failure == IdentityFileFailure.notFound
        ? IdentityFileFailure.sandboxDenied
        : failure;
  }

  Future<void> _record(
    ServerConfig config,
    String path, {
    Object? error,
  }) async {
    try {
      await _audit
          .record(
            IdentityReadEvent(
              at: DateTime.now().toUtc().toIso8601String(),
              serverId: config.id,
              serverLabel: config.label,
              path: path,
              viaBookmark: false,
              ok: error == null,
              error: error?.toString(),
            ),
          )
          .timeout(_auditTimeout);
    } on Object {
      // Best effort, as in Séance and Poltergeist: a full disk or a slow
      // write must not fail the connect.
    }
  }
}

/// The audit log in [supportDirectory], rotated through an owner-only
/// rewrite: it names private-key paths.
IdentityAuditLog identityAuditLogIn(String supportDirectory) =>
    IdentityAuditLog(
      File(
        '$supportDirectory${Platform.pathSeparator}$identityAuditLogFileName',
      ),
      rewriteOwnerOnly: _rewriteOwnerOnly,
    );

/// Reads at most [_maxIdentityFileBytes] of [path] as UTF-8. Throws a
/// [FileSystemException] for an I/O failure, anything but a regular file,
/// or a longer file, and a [FormatException] for bytes that are not UTF-8.
Future<String> _readBounded(String path) async {
  // Only a regular file is read, through any symlinks: open() on a FIFO
  // waits for a writer and a read from a character device such as a tty
  // waits for input, either of which may never come. A stat or read
  // stalled on a mount is bounded by the link supervisor's attempt
  // deadline instead.
  final type = (await FileStat.stat(path)).type;
  if (type != FileSystemEntityType.file) {
    // FileSystemEntityType has no device type: stat reports a device as
    // notFound, where File.exists finds it. A path that is really missing,
    // or that stat could not reach, falls through to open(), which says
    // which.
    final missing =
        type == FileSystemEntityType.notFound && !await File(path).exists();
    if (!missing) throw FileSystemException('Not a regular file', path);
  }

  final handle = await File(path).open();
  try {
    final bytes = BytesBuilder(copy: false);
    while (bytes.length <= _maxIdentityFileBytes) {
      final chunk = await handle.read(_maxIdentityFileBytes + 1 - bytes.length);
      if (chunk.isEmpty) break;
      bytes.add(chunk);
    }
    if (bytes.length > _maxIdentityFileBytes) {
      throw FileSystemException(
        'Larger than $_maxIdentityFileBytes bytes',
        path,
      );
    }
    return utf8.decode(bytes.takeBytes());
  } finally {
    await handle.close();
  }
}

/// Replaces [file] with [contents] atomically, restricting the temporary
/// file to its owner before anything is written to it, so the rotated log
/// is never readable by others, even briefly.
Future<void> _rewriteOwnerOnly(File file, String contents) async {
  final temporary = File('${file.path}.tmp-${uuidV4()}');
  try {
    await temporary.create(exclusive: true);
    restrictFileToOwner(temporary);
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(file.path);
    await syncLocalDirectory(file.parent);
  } on Object {
    try {
      if (await temporary.exists()) await temporary.delete();
    } on Object {
      // The rewrite's own failure is the one to report.
    }
    rethrow;
  }
}
