import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'fleet_controller.dart';
import 'sync_controller.dart';

/// What Settings reads and runs of the sync sign-out (03 §4.3), apart from
/// where it runs: [SyncSignOut] in the app, and a copy kept over the
/// settings link in the desktop settings window.
abstract interface class SyncSignOutSettings implements Listenable {
  /// The enrolled account, or null, which hides the sign-out.
  SyncAccountInfo? get account;

  /// Whether a sync operation is under way; the sign-out waits for it.
  bool get busy;

  /// How many of the servers a sign-out removes, those that came from the
  /// account, have an open connection now, which the sign-out closes.
  /// Asked when the confirmation opens rather than kept current, since
  /// link statuses change far more often than the account.
  Future<int> openConnectionsRemoved();

  /// Signs this device out. Throws [SyncSignOutFailedException] when the
  /// engine did not sign out.
  Future<void> signOut();
}

/// The engine did not sign out; [message] is a diagnostic, surfaces show
/// their own localized text.
final class SyncSignOutFailedException implements Exception {
  const SyncSignOutFailedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [SyncSignOutSettings] over the app's [SyncController] and
/// [FleetController]. It holds no state of its own, so it needs no
/// disposing: its listeners are the sync controller's.
final class SyncSignOut implements SyncSignOutSettings {
  SyncSignOut(this._sync, this._fleet);

  final SyncController _sync;
  final FleetController _fleet;

  @override
  SyncAccountInfo? get account => _sync.account;

  @override
  bool get busy => _sync.busy;

  @override
  Future<int> openConnectionsRemoved() async => openSyncedConnections(_fleet);

  @override
  Future<void> signOut() async {
    final status = await _sync.signOut();
    if (status.phase == SyncPhase.succeeded) return;
    throw SyncSignOutFailedException(
      [?status.failure?.name, ?status.detail].join(': '),
    );
  }

  @override
  void addListener(VoidCallback listener) => _sync.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _sync.removeListener(listener);
}

/// How many synced servers in [fleet] hold a usable link: the ones a
/// sign-out removes and whose connections it closes. Imports stay.
int openSyncedConnections(FleetController fleet) => fleet.servers
    .where(
      (server) =>
          server.origin == FleetEntryOrigin.synced &&
          switch (fleet.linkStatusFor(server.id)) {
            LinkReady() || LinkDegraded() => true,
            _ => false,
          },
    )
    .length;
