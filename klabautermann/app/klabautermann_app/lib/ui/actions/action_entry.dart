import 'package:flutter/widgets.dart';

import '../../controllers/operations_controller.dart';
import '../server_safety.dart';

/// Every place the app offers an action (SAF-06): one registry, so a
/// single test proves read-only hides each. E21 and E22 build the
/// entries; each wraps its control in an [ActionEntry] with its point.
enum ActionEntryPoint {
  /// The Processes tab's signal menu (PRC-02).
  processSignal,

  /// A unit's verbs on its page and in its row menu (SVC-03).
  unitVerb,

  /// "Run now" on a timer (JOB-08).
  timerRunNow,

  /// "Run now" on a cron line (JOB-19).
  cronRunNow,

  /// Pause and Resume on a cron line (JOB-07).
  cronPause,

  /// A container's state verbs (CTR-02).
  containerVerb,

  /// Removing a container (CTR-06).
  containerRemove,

  /// Removing an image (IMG-02).
  imageRemove,

  /// A stack's start, stop and restart (STK-03).
  stackVerb,

  /// A stack's pull and redeploy (STK-06).
  stackRedeploy,

  /// One service's start, stop, restart, pull, recreate and scale
  /// (STK-23).
  stackService,

  /// Taking a whole stack down, never with its volumes (STK-23).
  stackDown,

  /// Editing a file or a crontab (SAF-12, X-05), or restoring a backup
  /// into the editor.
  fileEdit,

  /// Keeping the newest backups, or removing a file's (SAF-14, Q11).
  backupRemove,
}

/// The operations controller for every route, which action entries plan
/// and run through. Absent in tests that leave it out.
class OperationsScope extends InheritedWidget {
  const OperationsScope({
    super.key,
    required this.operations,
    required super.child,
  });

  final OperationsController operations;

  static OperationsController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OperationsScope>()?.operations;

  @override
  bool updateShouldNotify(OperationsScope oldWidget) =>
      operations != oldWidget.operations;
}

/// Shows [child], an action's control at [point], only where actions on
/// [serverId] are allowed and not hidden: management on (SAF-01), the
/// server and the app not read-only (SAF-06). Without safety preferences
/// nothing is allowed. The engine refuses such plans too; hiding them
/// keeps screen sharing safe.
class ActionEntry extends StatelessWidget {
  const ActionEntry({
    super.key,
    required this.serverId,
    required this.point,
    required this.child,
  });

  final String serverId;
  final ActionEntryPoint point;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      actionsAllowedAt(context, serverId, point)
      ? child
      : const SizedBox.shrink();
}

/// Whether [point]'s actions on [serverId] show: management on (SAF-01),
/// neither the server nor the app read-only (SAF-06), and an operations
/// controller to run them. [ActionEntry] and the row menus that cannot
/// wrap a widget both ask this.
bool actionsAllowedAt(
  BuildContext context,
  String serverId,
  ActionEntryPoint point,
) {
  final safety = SafetyScope.maybeOf(context);
  if (safety == null || OperationsScope.maybeOf(context) == null) {
    return false;
  }
  final policy = safety.value;
  return serverSafetyIn(policy, serverId).management &&
      !serverReadOnlyIn(policy, serverId);
}
