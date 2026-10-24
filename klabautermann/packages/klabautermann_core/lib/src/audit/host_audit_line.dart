// The host's syslog line (SAF-13, 03 §8.10, M5 plan M19): one
// `logger -t klabautermann` line after each run, so every device and
// admin reads the same trail on the host.
import 'package:klabautermann_host/klabautermann_host.dart'
    show HostCommandError, HostCommands;

import '../operations/operation_plan.dart';

/// [plan] as the engine holds it: with the syslog line as its last,
/// best-effort step while the server's switch is [enabled], naming
/// [deviceName], the device name setting (M5 plan Q6). A detached plan
/// runs on the host past the session, where no step is best-effort, so
/// it keeps its steps; so does a plan whose action or target leaves no
/// word to log.
OperationPlan withHostAuditLine(
  OperationPlan plan, {
  required bool enabled,
  required String deviceName,
}) {
  if (!enabled || plan.detached) return plan;
  try {
    return plan.withAuditLine(
      HostCommands.auditLine(plan.kind.name, plan.targetName, deviceName),
    );
  } on HostCommandError {
    return plan;
  }
}
