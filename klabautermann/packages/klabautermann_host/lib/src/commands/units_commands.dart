part of 'commands.dart';

/// The `systemctl` verbs the unit view may run (03 §7.5).
enum SystemctlVerb {
  show,
  status,
  start,
  stop,
  restart,
  reload,
  enable,
  disable,
  mask,
  unmask,
  resetFailed('reset-failed');

  const SystemctlVerb([this._wireName]);

  final String? _wireName;

  /// The verb as `systemctl` spells it.
  String get wireName => _wireName ?? name;
}

/// The `systemctl show` properties SVC-08's per-unit resources read
/// (03 §7.5). `systemctl show` has no JSON output [R: systemd issue
/// #39081], so [parseUnitResources] reads its `KEY=VALUE` lines.
const List<String> kUnitResourceProperties = [
  'MemoryCurrent',
  'CPUUsageNSec',
  'TasksCurrent',
  'NRestarts',
  'MainPID',
  'ActiveEnterTimestamp',
];

/// The systemd manager a unit command addresses (03 §7.5, SVC-09): the
/// system manager, or the login user's own. A user-manager command never
/// runs under sudo, which would address root's manager instead; the
/// planner keeps it out of elevation.
final class UnitManager {
  /// The system manager (`systemctl` without `--user`).
  const UnitManager.system() : _user = false, runtimeDir = null;

  /// The login user's manager (`systemctl --user`), with [runtimeDir] as
  /// `XDG_RUNTIME_DIR` when the login session does not set it.
  const UnitManager.user({this.runtimeDir}) : _user = true;

  /// The login user's manager on a host whose probe recorded [uid] and
  /// the session's [xdgRuntimeDir] (03 §6.1). `systemctl --user` finds
  /// the manager's bus through `XDG_RUNTIME_DIR`; where the session left
  /// it unset, the command sets systemd's own `/run/user/<uid>` [U].
  factory UnitManager.userFor({int? uid, String? xdgRuntimeDir}) {
    final set = xdgRuntimeDir != null && xdgRuntimeDir.isNotEmpty;
    if (set || uid == null) return const UnitManager.user();
    return UnitManager.user(runtimeDir: '/run/user/$uid');
  }

  final bool _user;

  /// The `XDG_RUNTIME_DIR` a user-manager command sets, or null to keep
  /// the session's.
  final String? runtimeDir;

  /// Whether this is the login user's manager.
  bool get isUser => _user;

  /// The words before the `systemctl` verb.
  List<String> get _head {
    if (!_user) return const ['systemctl'];
    final dir = runtimeDir;
    if (dir == null) return const ['systemctl', '--user'];
    HostCommands._check(ArgValidators.absolutePath, dir);
    return ['env', 'XDG_RUNTIME_DIR=$dir', 'systemctl', '--user'];
  }
}

/// How [HostCommands.unitSockets] asks for its table: JSON on systemd
/// 246+, the `--no-legend` text table below (03 §6.4).
enum UnitTableFormat { json, text }
