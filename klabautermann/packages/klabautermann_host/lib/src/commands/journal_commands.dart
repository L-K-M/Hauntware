part of 'commands.dart';

/// The order `journalctl` reads in (03 §7.6, §10.1). journalctl refuses
/// `--reverse` together with `--follow`, so the two are one choice.
enum JournalOrder {
  /// Oldest first, journalctl's default.
  oldestFirst,

  /// Newest first (`-r`): a window, and its older pages after a cursor.
  newestFirst,

  /// Follow (`-f`): the earlier records oldest first, then each new one.
  follow,
}

/// One boot of the journal (LOG-09, 03 §7.6): an offset from the
/// current boot (0, -1 for the one before) or a boot ID, which stays
/// put when the host boots again.
final class JournalBoot {
  /// The boot [offset] boots before the current one; 0 is the current.
  const JournalBoot.offset(int offset) : _offset = offset, _id = null;

  /// The boot whose ID is [id], 32 lower-case hex digits.
  const JournalBoot.id(String id) : _offset = null, _id = id;

  final int? _offset;
  final String? _id;

  /// The offset, or null for a boot named by [id].
  int? get offset => _offset;

  /// The boot ID, or null for a boot named by [offset].
  String? get id => _id;

  @override
  bool operator ==(Object other) =>
      other is JournalBoot && other._offset == _offset && other._id == _id;

  @override
  int get hashCode => Object.hash(_offset, _id);

  @override
  String toString() => 'JournalBoot(${_id ?? _offset})';

  /// The `-b` argument, after validating it.
  String get _wire {
    final id = _id;
    if (id != null) {
      if (!_bootId.hasMatch(id)) {
        throw HostCommandError('not a boot ID', argument: id);
      }
      return id;
    }
    final offset = _offset!;
    if (offset > 0) {
      throw HostCommandError('a boot offset counts back', argument: '$offset');
    }
    return '$offset';
  }

  static final _bootId = RegExp(r'^[0-9a-f]{32}$');
}

/// The first systemd whose `journalctl --list-boots` takes `-o json`
/// (03 §7.6).
const int kListBootsJsonSystemd = 251;

/// How [HostCommands.journalBoots] asks for the boot list: JSON on
/// systemd [kListBootsJsonSystemd] and later, the text table below.
enum JournalBootsFormat { json, text }
