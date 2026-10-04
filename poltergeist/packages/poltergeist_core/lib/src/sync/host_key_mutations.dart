import 'package:seance_core/seance_core.dart';

/// Result of a conditional host-key write.
enum HostKeyInstallResult { installed, conflict }

/// A TOFU store that can reject a conflicting write atomically.
///
/// Sync uses this narrower contract because a separate `get` then `put`
/// could overwrite a key accepted by the connection engine between calls.
abstract interface class ConflictAwareHostKeyStore implements HostKeyStore {
  Future<HostKeyInstallResult> putIfNoConflict(HostKey key);

  /// Replaces [expected] only while its fingerprint is still current.
  Future<HostKeyInstallResult> replaceIfCurrent(
    HostKey expected,
    HostKey replacement,
  );
}

/// Serializes coordinator-owned trust and verdict mutations.
///
/// One gate must outlive coordinator rebuilds so a pending forget cannot
/// overlap auto-application in the replacement coordinator.
final class HostKeyMutationGate {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// In-memory implementation for tests and ephemeral compositions.
final class InMemoryConflictAwareHostKeyStore
    implements ConflictAwareHostKeyStore {
  final Map<String, HostKey> _keys = {};
  Future<void> _tail = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<List<HostKey>> all() =>
      _serialize(() async => _keys.values.toList(growable: false));

  @override
  Future<HostKey?> get(String host, int port) =>
      _serialize(() async => _keys['$host:$port']);

  @override
  Future<void> put(HostKey key) =>
      _serialize(() async => _keys[key.locator] = key);

  @override
  Future<HostKeyInstallResult> putIfNoConflict(HostKey key) =>
      _serialize(() async {
        final current = _keys[key.locator];
        if (current != null && current.conflictsWith(key)) {
          return HostKeyInstallResult.conflict;
        }

        _keys[key.locator] = key;
        return HostKeyInstallResult.installed;
      });

  @override
  Future<HostKeyInstallResult> replaceIfCurrent(
    HostKey expected,
    HostKey replacement,
  ) {
    if (expected.locator != replacement.locator) {
      throw ArgumentError.value(
        replacement.locator,
        'replacement',
        'must use the expected host-key locator',
      );
    }

    return _serialize(() async {
      final current = _keys[expected.locator];
      if (current == null ||
          current.fingerprintSha256 != expected.fingerprintSha256) {
        return HostKeyInstallResult.conflict;
      }

      _keys[replacement.locator] = replacement;
      return HostKeyInstallResult.installed;
    });
  }
}
