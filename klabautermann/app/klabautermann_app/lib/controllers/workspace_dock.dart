import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'operations_controller.dart';

/// What the desktop workspace's bottom dock (OV-10) holds: logs, a run's
/// output or a container shell, each of one server, so they stay in
/// sight under whichever panel shows.
@immutable
sealed class DockItem {
  const DockItem(this.serverId);

  final String serverId;
}

/// The server's journal, followed as the Logs tab reads it.
final class DockedLogs extends DockItem {
  const DockedLogs(super.serverId);

  @override
  bool operator ==(Object other) =>
      other is DockedLogs && other.serverId == serverId;

  @override
  int get hashCode => Object.hash(DockedLogs, serverId);
}

/// A unit run's journal, followed from shortly before the run (JOB-08).
final class DockedRunOutput extends DockItem {
  const DockedRunOutput(super.serverId, this.unit);

  final String unit;

  @override
  bool operator ==(Object other) =>
      other is DockedRunOutput &&
      other.serverId == serverId &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(DockedRunOutput, serverId, unit);
}

/// A cron line's or snippet's run [planId] and what it printed (JOB-19,
/// AUT-01), which [operations] holds; [title] is the target its preview
/// named.
final class DockedCommandRun extends DockItem {
  const DockedCommandRun(
    super.serverId, {
    required this.operations,
    required this.planId,
    required this.title,
  });

  final OperationsController operations;
  final String planId;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is DockedCommandRun &&
      other.serverId == serverId &&
      other.planId == planId;

  @override
  int get hashCode => Object.hash(DockedCommandRun, serverId, planId);
}

/// A shell in [container] (CTX-07), which closes when its tab does.
final class DockedShell extends DockItem {
  const DockedShell(super.serverId, this.container);

  final ContainerSummary container;

  @override
  bool operator ==(Object other) =>
      other is DockedShell &&
      other.serverId == serverId &&
      other.container.id == container.id;

  @override
  int get hashCode => Object.hash(DockedShell, serverId, container.id);
}

/// The desktop workspace's bottom dock (OV-10): every item opened this
/// run, by server, the one each server shows, and whether the dock is
/// expanded. The desktop shell owns it; phones have no dock and show the
/// same content in bottom sheets and pages instead.
final class WorkspaceDock extends ChangeNotifier {
  final List<DockItem> _items = [];
  final Map<String, DockItem> _selected = {};
  bool _expanded = false;

  /// Every open item, in the order each was opened.
  List<DockItem> get items => List.unmodifiable(_items);

  /// [serverId]'s items, in the order each was opened.
  List<DockItem> itemsFor(String serverId) => [
    for (final item in _items)
      if (item.serverId == serverId) item,
  ];

  /// The item [serverId]'s dock shows, or null when it holds none.
  DockItem? selectedFor(String serverId) => _selected[serverId];

  /// Whether the dock shows its items' content or only their tabs.
  bool get expanded => _expanded;

  /// Opens [item], or brings it forward when it is open, and expands the
  /// dock to show it.
  void show(DockItem item) {
    final index = _items.indexOf(item);
    if (index < 0) {
      _items.add(item);
    } else {
      // An equal item with newer details, such as a renamed container,
      // takes the old one's place.
      _items[index] = item;
    }
    _selected[item.serverId] = item;
    _expanded = true;
    notifyListeners();
  }

  /// Brings [item], which is open, forward in its server's dock.
  void select(DockItem item) {
    if (!_items.contains(item)) return;
    _selected[item.serverId] = item;
    _expanded = true;
    notifyListeners();
  }

  /// Closes [item]; its server's dock then shows the item opened before
  /// it, or the one after when it was the first.
  void close(DockItem item) {
    final index = _items.indexOf(item);
    if (index < 0) return;
    _items.removeAt(index);
    if (_selected[item.serverId] == item) {
      final rest = itemsFor(item.serverId);
      if (rest.isEmpty) {
        _selected.remove(item.serverId);
      } else {
        final before = _items
            .take(index)
            .where((other) => other.serverId == item.serverId);
        _selected[item.serverId] = before.isEmpty ? rest.first : before.last;
      }
    }
    notifyListeners();
  }

  /// Closes every item of a server that left the fleet.
  void forgetServer(String serverId) {
    final before = _items.length;
    _items.removeWhere((item) => item.serverId == serverId);
    final removed = _selected.remove(serverId) != null;
    if (_items.length != before || removed) notifyListeners();
  }

  /// Expands or collapses the dock; a collapsed dock keeps its items.
  void setExpanded(bool expanded) {
    if (expanded == _expanded) return;
    _expanded = expanded;
    notifyListeners();
  }
}
