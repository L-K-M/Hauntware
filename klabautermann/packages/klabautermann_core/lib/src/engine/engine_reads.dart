import 'dart:async';

import 'package:klabautermann_host/klabautermann_host.dart' show HostProfile;
import 'package:seance_core/seance_core.dart' show SshLink;

import '../admin/admin_mode.dart';
import '../admin/firewall.dart';
import '../admin/restarts.dart';
import '../admin/smart.dart';
import '../admin/sshd_posture.dart';
import '../admin/user_crontabs.dart';
import '../audit/audit_log.dart';
import '../history/history_store.dart';
import '../jobs/job_history_query.dart';
import '../links/link_supervisor.dart';
import '../operations/edit_reader.dart';
import '../operations/stack_edits.dart';
import '../services/accounts.dart';
import '../services/disk_usage.dart';
import '../services/packages.dart';
import '../services/timer_detail.dart';
import '../services/unit_queries.dart';
import 'protocol.dart';

/// The engine's read handlers (ENG-11 step 5, ARC-05), moved out of
/// `engineMain`'s `handle` switch so one isolate turn still answers each
/// request in arrival order, but each read's shape lives in one place.
///
/// Every dependency is fixed at construction, except [fleetIds], whose set
/// the fleet refresh replaces, and is read through a getter so a handler
/// always sees the fleet as it is now.
final class EngineReads {
  EngineReads({
    required this._links,
    required this._admin,
    required this._audit,
    required this._history,
    required this._profiles,
    required this._packageReports,
    required this._diskTrees,
    required this._fleetIds,
    required this._stackEditLookup,
    required this._lendSession,
    required this._send,
  });

  final LinkSupervisor? _links;
  final AdminModeController? _admin;
  final AuditLog _audit;
  final HistoryStore? _history;
  final Map<String, HostProfile> _profiles;
  final PackageReports _packageReports;
  final DiskUsageTrees _diskTrees;
  final Set<String> Function() _fleetIds;
  final StackEditLookup? Function(String serverId) _stackEditLookup;
  final Future<T> Function<T>(String serverId, Future<T> Function() body)
  _lendSession;
  final void Function(EngineEvent event) _send;

  /// Answers a read that runs under an admin session: a server with no
  /// ready link answers [onFailure]([noLink]), one whose admin mode is off
  /// answers [onFailure]([adminRequired]), and otherwise [read] lends the
  /// session, whose answer is sent. A throw answers
  /// [onFailure]([transport]), so the request always settles.
  ///
  /// Unlike [linkRead], the server need not be in the fleet: an admin read
  /// answers any server the engine has a link to.
  void adminRead<E extends EngineEvent, F extends Enum>(
    String serverId, {
    required E Function(F failure) onFailure,
    required F noLink,
    required F adminRequired,
    required F transport,
    required Future<E> Function(AdminSession session) read,
  }) {
    if (_links?.link(serverId) == null) {
      _send(onFailure(noLink));
      return;
    }
    final session = _admin?.session(serverId);
    if (session == null) {
      _send(onFailure(adminRequired));
      return;
    }
    _admin?.touch(serverId);
    // Not awaited: one elevated command per user, and the queue keeps
    // serving the app meanwhile; a lend that fails still answers.
    unawaited(
      _lendSession(
        serverId,
        () => read(session),
      ).then(_send, onError: (Object _) => _send(onFailure(transport))),
    );
  }

  /// Answers a read that needs only a link: a server outside the fleet or
  /// without one answers [onFailure]([noLink]); [ready] adds another noLink
  /// condition. Otherwise [read] lends the link, its answer is sent, and a
  /// throw answers [onTransport]. When [adminRequired] is set the read also
  /// needs that admin session, which is touched as the admin reads do.
  void linkRead<E extends EngineEvent, F extends Enum>(
    String serverId, {
    required E Function(F failure) onFailure,
    required F noLink,
    required Future<E> Function(SshLink link, AdminSession? session) read,
    required void Function(Object error) onTransport,
    bool Function()? ready,
    F? adminRequired,
  }) {
    final link = _links?.link(serverId);
    if (!_fleetIds().contains(serverId) ||
        link == null ||
        (ready != null && !ready())) {
      _send(onFailure(noLink));
      return;
    }
    final session = adminRequired == null ? null : _admin?.session(serverId);
    if (adminRequired != null && session == null) {
      _send(onFailure(adminRequired));
      return;
    }
    if (session != null) _admin?.touch(serverId);
    // Not awaited, as the other reads: the queue keeps serving the app
    // meanwhile, and a lend that fails still answers.
    unawaited(read(link, session).then(_send, onError: onTransport));
  }

  void editable(ReadEditable message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    // The read runs with the profile the request found, even when a
    // re-probe drops it while the read waits for the session.
    final profile = _profiles[serverId];
    linkRead<EditRead, EditReadFailure>(
      serverId,
      onFailure: (failure) => EditRead(
        serverId: serverId,
        requestId: requestId,
        result: EditReadFailed(failure),
      ),
      noLink: EditReadFailure.noLink,
      // A file read needs the probe's facts as much as the link.
      ready: () => profile != null,
      onTransport: (Object error) => _send(
        EditRead(
          serverId: serverId,
          requestId: requestId,
          result: EditReadFailed(EditReadFailure.failed, detail: '$error'),
        ),
      ),
      read: (link, _) => _lendSession(
        serverId,
        () async => EditRead(
          serverId: serverId,
          requestId: requestId,
          result: await readEditable(message.target, (
            link: link,
            profile: profile!,
            admin: _admin?.session(serverId),
          ), stacks: _stackEditLookup(serverId)),
        ),
      ),
    );
  }

  Future<void> audit(AuditQuery message) async {
    final serverId = message.serverId;
    // The query names no id a rejection could echo, and the app
    // matches answers by server: a read that throws answers as a log
    // that could not be read, so the page waiting on it settles.
    try {
      final (:records, :next, :unreadable) = await _audit.query(
        serverId,
        after: message.after,
        limit: message.limit,
      );
      _send(
        AuditRecords(serverId, records, next: next, unreadable: unreadable),
      );
    } on Object {
      _send(AuditRecords(serverId, const [], unreadable: true));
    }
  }

  Future<void> history(ReadHistory message) async {
    const nothing = HistoryRange(buckets: [], gaps: []);
    final serverId = message.serverId;
    // The app waits on the answer, so a read that fails answers
    // nothing recorded rather than nothing at all. A server outside
    // the fleet, such as one a view still shows while it is removed,
    // has no history to read.
    final store = _fleetIds().contains(serverId) ? _history : null;
    final range =
        await (store?.read(
                  serverId,
                  message.tier,
                  now: DateTime.now().toUtc(),
                ) ??
                Future.value(nothing))
            .catchError((Object _) => nothing);
    _send(
      HistoryRead(
        requestId: message.requestId,
        serverId: serverId,
        tier: message.tier,
        range: range,
      ),
    );
  }

  void userCrontabs(ReadUserCrontabs message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    adminRead<UserCrontabs, UserCrontabsFailure>(
      serverId,
      onFailure: (failure) => UserCrontabs(
        serverId: serverId,
        requestId: requestId,
        failure: failure,
      ),
      noLink: UserCrontabsFailure.noLink,
      adminRequired: UserCrontabsFailure.adminRequired,
      transport: UserCrontabsFailure.transport,
      read: (session) => readUserCrontabs(
        serverId,
        requestId: requestId,
        session: session,
        profile: _profiles[serverId],
        now: DateTime.now().toUtc(),
      ),
    );
  }

  void accounts(ReadAccounts message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    linkRead<AccountsReport, AccountsReportFailure>(
      serverId,
      onFailure: (failure) => AccountsReport(
        serverId: serverId,
        requestId: requestId,
        failure: failure,
      ),
      noLink: AccountsReportFailure.noLink,
      onTransport: (Object _) => _send(
        AccountsReport(
          serverId: serverId,
          requestId: requestId,
          failure: AccountsReportFailure.transport,
        ),
      ),
      read: (link, _) => _lendSession(
        serverId,
        () => readAccounts(serverId, requestId: requestId, link: link),
      ),
    );
  }

  void diskUsage(ReadDiskUsage message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    final path = message.path;
    linkRead<DiskUsageReport, DiskUsageReportFailure>(
      serverId,
      onFailure: (failure) => DiskUsageReport(
        serverId: serverId,
        requestId: requestId,
        path: path,
        failure: failure,
      ),
      noLink: DiskUsageReportFailure.noLink,
      // Only an elevated read needs the admin session.
      adminRequired: message.elevated
          ? DiskUsageReportFailure.adminRequired
          : null,
      onTransport: (Object _) => _send(
        DiskUsageReport(
          serverId: serverId,
          requestId: requestId,
          path: path,
          failure: DiskUsageReportFailure.transport,
        ),
      ),
      read: (link, session) async {
        // A folder under the explorer's mount point answers from one
        // export of the whole filesystem where ncdu or gdu is installed
        // ([diskUsageFromTree]); any other read, or a folder the export
        // dropped, reads with du.
        final tool = diskUsageExportToolOf(_profiles[serverId]);
        if (message.root != null &&
            tool != null &&
            diskUsageFromTree(
              path: path,
              root: message.root!,
              fresh: message.fresh,
            )) {
          final tree = await _diskTrees.tree(
            serverId,
            message.root!,
            elevated: message.elevated,
            fresh: message.fresh,
            read: (cancelled) => _lendSession(
              serverId,
              () => readDiskUsageTree(
                message.root!,
                tool: tool,
                link: link,
                session: session,
                cancelled: cancelled,
              ),
            ),
          );
          if (tree?.listing(path) case final listing?) {
            return DiskUsageReport(
              serverId: serverId,
              requestId: requestId,
              path: path,
              listing: listing,
            );
          }
        }
        return _lendSession(
          serverId,
          () => readDiskUsage(
            serverId,
            path,
            requestId: requestId,
            link: link,
            session: session,
          ),
        );
      },
    );
  }

  void timerDetail(ReadTimerDetail message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    final unit = message.unit;
    final user = message.user;
    linkRead<TimerDetailReport, TimerDetailFailure>(
      serverId,
      onFailure: (failure) => TimerDetailReport(
        serverId: serverId,
        requestId: requestId,
        unit: unit,
        user: user,
        failure: failure,
      ),
      noLink: TimerDetailFailure.noLink,
      onTransport: (Object _) => _send(
        TimerDetailReport(
          serverId: serverId,
          requestId: requestId,
          unit: unit,
          user: user,
          failure: TimerDetailFailure.transport,
        ),
      ),
      read: (link, _) => _lendSession(
        serverId,
        () => readTimerDetail(
          serverId,
          unit,
          requestId: requestId,
          link: link,
          user: user,
          profile: _profiles[serverId],
        ),
      ),
    );
  }

  void smart(ReadSmart message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    adminRead<SmartReport, SmartReportFailure>(
      serverId,
      onFailure: (failure) => SmartReport(
        serverId: serverId,
        requestId: requestId,
        failure: failure,
      ),
      noLink: SmartReportFailure.noLink,
      adminRequired: SmartReportFailure.adminRequired,
      transport: SmartReportFailure.transport,
      read: (session) => readSmart(
        serverId,
        requestId: requestId,
        session: session,
        profile: _profiles[serverId],
      ),
    );
  }

  void restarts(ReadRestarts message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    adminRead<RestartReport, RestartReportFailure>(
      serverId,
      onFailure: (failure) => RestartReport(
        serverId: serverId,
        requestId: requestId,
        failure: failure,
      ),
      noLink: RestartReportFailure.noLink,
      adminRequired: RestartReportFailure.adminRequired,
      transport: RestartReportFailure.transport,
      read: (session) =>
          readRestarts(serverId, requestId: requestId, session: session),
    );
  }

  void firewall(ReadFirewall message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    adminRead<FirewallReport, FirewallReportFailure>(
      serverId,
      onFailure: (failure) => FirewallReport(
        serverId: serverId,
        requestId: requestId,
        failure: failure,
      ),
      noLink: FirewallReportFailure.noLink,
      adminRequired: FirewallReportFailure.adminRequired,
      transport: FirewallReportFailure.transport,
      read: (session) =>
          readFirewall(serverId, requestId: requestId, session: session),
    );
  }

  void sshdPosture(ReadSshdPosture message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    adminRead<SshdPostureReport, SshdPostureFailure>(
      serverId,
      onFailure: (failure) => SshdPostureReport(
        serverId: serverId,
        requestId: requestId,
        failure: failure,
      ),
      noLink: SshdPostureFailure.noLink,
      adminRequired: SshdPostureFailure.adminRequired,
      transport: SshdPostureFailure.transport,
      read: (session) => readSshdPosture(
        serverId,
        requestId: requestId,
        session: session,
        profile: _profiles[serverId],
      ),
    );
  }

  void packages(ReadPackages message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    linkRead<PackagesReport, PackagesReportFailure>(
      serverId,
      onFailure: (failure) => PackagesReport(
        serverId: serverId,
        requestId: requestId,
        failure: failure,
      ),
      noLink: PackagesReportFailure.noLink,
      onTransport: (Object _) => _send(
        PackagesReport(
          serverId: serverId,
          requestId: requestId,
          failure: PackagesReportFailure.transport,
        ),
      ),
      // The tracker may answer from its kept check without a read.
      read: (link, _) => _packageReports.read(
        serverId,
        requestId: requestId,
        fresh: message.fresh,
        check: () => _lendSession(
          serverId,
          () => readPackages(
            serverId,
            requestId: requestId,
            link: link,
            now: () => DateTime.now().toUtc(),
          ),
        ),
      ),
    );
  }

  void units(UnitQuery message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    // The read runs with the profile the request found, even when a
    // re-probe drops it while the read waits for the session.
    final profile = _profiles[serverId];
    linkRead<UnitQueryResult, UnitQueryFailure>(
      serverId,
      onFailure: (failure) => UnitQueryResult(
        serverId: serverId,
        requestId: requestId,
        payload: UnitQueryFailed(failure),
      ),
      noLink: UnitQueryFailure.noLink,
      // A unit query runs with the profile's manager and units.
      ready: () => profile != null,
      onTransport: (Object error) => _send(
        UnitQueryResult(
          serverId: serverId,
          requestId: requestId,
          payload: UnitQueryFailed(UnitQueryFailure.failed, detail: '$error'),
        ),
      ),
      read: (link, _) => _lendSession(
        serverId,
        () => runUnitQuery(
          serverId,
          requestId,
          message.query,
          link: link,
          profile: profile!,
        ),
      ),
    );
  }

  void jobHistory(JobHistoryQuery message) {
    final serverId = message.serverId;
    final requestId = message.requestId;
    linkRead<JobHistoryResult, JobHistoryFailure>(
      serverId,
      onFailure: (failure) => JobHistoryResult(
        serverId: serverId,
        requestId: requestId,
        payload: JobHistoryFailed(failure),
      ),
      noLink: JobHistoryFailure.noLink,
      onTransport: (Object error) => _send(
        JobHistoryResult(
          serverId: serverId,
          requestId: requestId,
          payload: JobHistoryFailed(JobHistoryFailure.failed, detail: '$error'),
        ),
      ),
      read: (link, _) => _lendSession(
        serverId,
        () => runJobHistoryQuery(
          serverId,
          requestId,
          message.query,
          link: link,
          admin: _admin?.session(serverId),
        ),
      ),
    );
  }
}
