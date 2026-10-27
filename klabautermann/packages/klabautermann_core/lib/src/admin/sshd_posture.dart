// SEC-01's sshd posture (03 §7.10): in admin mode, one elevated
// `sshd -T -C` naming the app's own connection from the probe, so the
// `Match` blocks that apply to it are applied.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show ElevationException, RemoteCommandException;

import '../engine/protocol.dart';
import 'admin_mode.dart';

/// Reads [serverId]'s sshd configuration through [session], for the
/// login user and connection [profile] names.
Future<SshdPostureReport> readSshdPosture(
  String serverId, {
  required String requestId,
  required AdminSession session,
  required HostProfile? profile,
}) async {
  SshdPostureReport failed(SshdPostureFailure failure, {String? detail}) =>
      SshdPostureReport(
        serverId: serverId,
        requestId: requestId,
        failure: failure,
        detail: detail,
      );

  try {
    final result = await session.executor.run(
      HostCommands.sshdPosture(
        user: profile?.user,
        sshConnection: profile?.sshConnection,
      ),
      password: session.password,
    );
    return switch (parseSshdPosture(result.stdout)) {
      SshdConfig(:final posture) => SshdPostureReport(
        serverId: serverId,
        requestId: requestId,
        posture: posture,
      ),
      SshdMissing() => failed(SshdPostureFailure.missing),
      SshdFailed(:final detail) => failed(
        SshdPostureFailure.refused,
        detail: detail,
      ),
      null => failed(SshdPostureFailure.unreadable),
    };
  } on ElevationException {
    return failed(SshdPostureFailure.elevationRefused);
  } on RemoteCommandException {
    return failed(SshdPostureFailure.transport);
  }
}
