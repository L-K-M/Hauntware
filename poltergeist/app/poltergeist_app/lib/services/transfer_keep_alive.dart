import 'dart:async';

import 'package:ghost_keepalive/ghost_keepalive.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/app_transfer_queue.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Poltergeist's strings for the shared keep-alive's notification. Reads
/// the English [AppLocalizations] directly (its constructor is public) so
/// the reporter needs no BuildContext: the notification is rebuilt in the
/// service, not the widget tree.
class PoltergeistKeepAliveStrings implements KeepAliveStrings {
  const PoltergeistKeepAliveStrings();

  @override
  String get channelId => 'poltergeist.keepalive';

  @override
  String get channelName => _l10n.keepAliveChannelName;

  @override
  String get channelDescription => _l10n.keepAliveChannelDescription;

  @override
  String get notificationTitle => _l10n.appTitle;

  @override
  String notificationText(int count) =>
      _l10n.keepAliveNotificationText(count);

  @override
  String get smallIconResourceName => 'ic_stat_transfer_keep_alive';

  static final AppLocalizations _l10n = AppLocalizationsEn();
}

/// D32's transfer foreground service: while the composed queue has any
/// non-terminal task (queued, running, paused: transfers, sync runs and
/// archive jobs alike), the shared keep-alive anchors the process so
/// Android cannot freeze it mid-work. The count, not the task identities,
/// is all the anchor needs; the state machine's 0 → n / n → 0 edges are
/// its own (see ghost_keepalive's BackgroundKeepAlive).
final class TransferKeepAliveReporter {
  TransferKeepAliveReporter({
    required AppTransferQueue queue,
    required this._keepAlive,
  }) : _queue = queue {
    _subscription = queue.events.listen((_) => _refresh());
    _refresh();
  }

  final AppTransferQueue _queue;
  final BackgroundKeepAlive _keepAlive;
  late final StreamSubscription<TransferQueueEvent> _subscription;

  void _refresh() {
    _keepAlive.refresh(
      _queue.tasks.where((task) => !task.isTerminal).length,
    );
  }

  /// Stops listening and drops the anchor immediately, without the grace,
  /// for teardown, where nothing will re-anchor afterwards.
  void dispose() {
    unawaited(_subscription.cancel());
    _keepAlive.stop();
  }
}
