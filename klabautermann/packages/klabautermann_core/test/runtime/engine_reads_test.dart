import 'dart:async';
import 'dart:io';

import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/audit/audit_log.dart';
import 'package:klabautermann_core/src/runtime/engine_reads.dart';
import 'package:klabautermann_core/src/engine/protocol.dart';
import 'package:klabautermann_core/src/links/link_connector.dart';
import 'package:klabautermann_core/src/links/link_supervisor.dart';
import 'package:klabautermann_core/src/links/prompt_broker.dart';
import 'package:klabautermann_core/src/services/disk_usage.dart';
import 'package:klabautermann_core/src/services/packages.dart';
import 'package:seance_core/seance_core.dart'
    show AuthMethod, ServerConfig, SshLink;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _serverId = 's1';

/// The helpers' contract (ENG-9): a read with no link answers its `noLink`
/// failure, one whose admin mode is off answers `adminRequired`, and a link
/// read outside the fleet answers `noLink` even when a link exists.
void main() {
  late List<dynamic> events;

  EngineReads reads({
    LinkSupervisor? links,
    AdminModeController? admin,
    Set<String> fleetIds = const {},
  }) {
    events = [];
    return EngineReads(
      links: links,
      admin: admin,
      audit: AuditLog(Directory.systemTemp, storage: AuditStorage.memory),
      history: null,
      profiles: const {},
      packageReports: PackageReports(now: DateTime.now),
      diskTrees: DiskUsageTrees(),
      fleetIds: () => fleetIds,
      stackEditLookup: (_) => null,
      lendSession: <T>(String serverId, Future<T> Function() body) => body(),
      send: events.add,
    );
  }

  test('an admin read with no link answers its noLink failure', () {
    reads().smart(ReadSmart(_serverId, requestId: 'r1'));

    expect(
      events.single,
      isA<SmartReport>().having(
        (event) => event.failure,
        'failure',
        SmartReportFailure.noLink,
      ),
    );
  });

  test('an admin read with a link but no admin session answers '
      'adminRequired', () async {
    final link = ScriptedLink();
    final admin = AdminModeController(
      linkFor: (id) => id == _serverId ? link : null,
      endpointOf: (_) => null,
      prompts: PromptBroker(emit: (_) {}),
      emit: (_) {},
    );

    reads(
      links: await _supervisorWith(link),
      admin: admin,
      fleetIds: {_serverId},
    ).smart(ReadSmart(_serverId, requestId: 'r1'));

    expect(
      events.single,
      isA<SmartReport>().having(
        (event) => event.failure,
        'failure',
        SmartReportFailure.adminRequired,
      ),
    );
  });

  test('a link read for a server outside fleetIds answers noLink even with '
      'a link', () async {
    final link = ScriptedLink();

    reads(
      links: await _supervisorWith(link),
    ).accounts(ReadAccounts(_serverId, requestId: 'r1'));

    expect(
      events.single,
      isA<AccountsReport>().having(
        (event) => event.failure,
        'failure',
        AccountsReportFailure.noLink,
      ),
    );
  });
}

/// A supervisor holding [link] ready for [_serverId], as an interactive
/// connect would leave it.
Future<LinkSupervisor> _supervisorWith(SshLink link) async {
  Completer<LinkConnectResult>? dial;
  final supervisor = LinkSupervisor(
    connect:
        (
          config, {
          required purpose,
          required changedKey,
          onPhase,
          onDialing,
          abandoned,
        }) => (dial ??= Completer<LinkConnectResult>()).future,
    configFor: (id) => id == _serverId ? _config(id) : null,
    emit: (_) {},
    policy: BackgroundLinkPolicy.keepOpen,
  );
  supervisor.connect(_serverId, purpose: ConnectPurpose.interactive);
  await pumpEventQueue();
  dial!.complete(LinkConnected(link));
  await pumpEventQueue();
  return supervisor;
}

ServerConfig _config(String id) => ServerConfig(
  id: id,
  label: id,
  host: '192.0.2.10',
  port: 22,
  username: 'me',
  authMethod: AuthMethod.agent,
  createdAt: 0,
  updatedAt: 0,
);
