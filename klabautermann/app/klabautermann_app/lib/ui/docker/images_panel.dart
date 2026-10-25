import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ghostFormatBinarySize, ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import '../actions/docker_actions.dart'
    show ImageActionsButton, PruneButton, imageActionEntries;
import '../sortable_table.dart';
import 'image_pull.dart' show ImagePullButton;
import 'containers_panel.dart' show DockerNotice;
import 'containers_view.dart' show searchTerms;
import 'docker_cells.dart';
import 'images_view.dart';

/// The panel width from which the images show as the sortable table;
/// narrower, as on a phone, they show as two-line rows. It grows with the
/// text scale, as the Containers sub-tab's does.
const double _wideWidth = 600;

/// The share of its height the header takes before it scrolls, so large
/// text never pushes the list out of sight.
const double _headerShare = 0.4;

/// The Images sub-tab (03 §7.14 IMG-01): every image by its tags, short
/// id, size in IEC units, age and date of creation, and whether any
/// container uses it, a dangling one marked by word, with a filter for
/// the unused or the dangling ones and a search by tag or ID.
///
/// While [visible], it holds the server's image watch
/// ([DockerController.watchImages]), which reads the containers too:
/// they tell which images are in use ([imageContainerCount]). Hidden, it
/// lets the watch go. A failed read keeps the last list under why it
/// failed. The ages follow the monitoring clock while the tab shows.
class ImagesPanel extends StatefulWidget {
  const ImagesPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool visible;

  @override
  State<ImagesPanel> createState() => _ImagesPanelState();
}

class _ImagesPanelState extends State<ImagesPanel> {
  /// What the clock's listeners hear instead while nothing ages.
  static final Listenable _silent = Listenable.merge(const []);

  /// The order, search and filter, which outlive sub-tab switches: the
  /// tab keeps a sub-tab built once opened.
  TableSort _sort = TableSort(
    ImageColumn.tags.name,
    TableSortDirection.ascending,
  );
  final _search = TextEditingController();
  ImageFilter _filter = ImageFilter.all;

  /// The server whose image watch this panel holds, if any.
  String? _held;

  DockerController get _docker => widget.monitoring.docker;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ImagesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId != oldWidget.serverId) {
      // Another server's images.
      _release();
      _search.clear();
    }
    _sync();
  }

  @override
  void dispose() {
    _release();
    _search.dispose();
    super.dispose();
  }

  void _sync() {
    final wanted = widget.visible ? widget.serverId : null;
    if (_held == wanted) return;
    _release();
    if (wanted == null) return;

    _docker.watchImages(wanted);
    _held = wanted;
  }

  void _release() {
    final held = _held;
    if (held == null) return;

    _held = null;
    _docker.unwatchImages(held);
  }

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final images = _docker.imagesFor(widget.serverId);
    final containers = _docker.containersFor(widget.serverId);
    final endpoint = _docker.endpointFor(widget.serverId);
    return ListenableBuilder(
      listenable: Listenable.merge([images, containers, endpoint]),
      builder: (context, _) =>
          _build(context, images.value, containers.value, endpoint.value),
    );
  }

  Widget _build(
    BuildContext context,
    DockerImageList list,
    DockerContainerList containers,
    DockerEndpointState? endpoint,
  ) {
    final l10n = AppLocalizations.of(context);
    final images = list.images;
    final failure = list.failure;
    final clock = widget.visible && (images?.isNotEmpty ?? false)
        ? widget.monitoring.clock
        : _silent;
    // Without a container list, an image list from before API 1.51 tells
    // nothing of use.
    final useUnknown =
        containers.containers == null &&
        containers.failure != null &&
        (images?.any((image) => imageContainerCount(image, null) == null) ??
            false);

    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >= MediaQuery.textScalerOf(context).scale(_wideWidth);
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            // On the socket forward the events stream costs no session,
            // so low-session mode changes nothing the list shows.
            if ((endpoint?.lowSession ?? false) &&
                endpoint?.route?.rank != DockerRank.streamlocal)
              DockerNotice(
                icon: Icons.speed_outlined,
                text: l10n.dockerImagesLowSessionRelay,
              ),
            if (failure != null) ...[
              DockerNotice(
                icon: Icons.error_outline,
                text: l10n.dockerImagesFailed(failure.failure.name),
                detail: failure.detail,
                action: TextButton(
                  onPressed: () => _docker.retryImages(widget.serverId),
                  child: Text(l10n.dockerRetry),
                ),
              ),
              if (images != null)
                DockerNotice(icon: Icons.history, text: l10n.dockerImagesKept),
            ] else if (images == null)
              DockerNotice(
                icon: Icons.hourglass_empty,
                text: l10n.dockerImagesReading,
              ),
            if (useUnknown)
              DockerNotice(
                icon: Icons.error_outline,
                text: l10n.dockerImagesUseUnknown,
                detail: containers.failure?.detail,
              ),
            if (images != null &&
                actionsAllowedAt(
                  context,
                  widget.serverId,
                  ActionEntryPoint.prune,
                ))
              Align(
                alignment: AlignmentDirectional.centerStart,
                // Pull and prune share the server's action policy.
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ImagePullButton(serverId: widget.serverId),
                    PruneButton(
                      choices: [
                        PruneDocker(
                          widget.serverId,
                          kind: DockerPruneKind.images,
                        ),
                        PruneDocker(
                          widget.serverId,
                          kind: DockerPruneKind.images,
                          all: true,
                        ),
                        PruneDocker(
                          widget.serverId,
                          kind: DockerPruneKind.buildCache,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (images != null) _filters(l10n),
            if (images != null && !wide) _sortControls(l10n),
          ],
        );
        final padding = EdgeInsets.all(wide ? 20 : 16);
        if (images == null) {
          return SingleChildScrollView(padding: padding, child: header);
        }

        return Padding(
          padding: padding,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * _headerShare,
                  ),
                  child: SingleChildScrollView(child: header),
                ),
                const SizedBox(height: 12),
                Expanded(
                  // Only the ages move with the clock.
                  child: ListenableBuilder(
                    listenable: clock,
                    builder: (context, _) => _body(
                      context,
                      images,
                      containers.containers,
                      wide: wide,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    List<ImageSummary> images,
    List<ContainerSummary>? containers, {
    required bool wide,
  }) {
    final l10n = AppLocalizations.of(context);
    final columns = _columns(context, l10n, widget.monitoring.clock.value);
    final terms = searchTerms(_search.text);
    final entries = imageEntries(
      images,
      containers: containers,
      filter: _filter,
      terms: terms,
    );
    final empty = Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        images.isEmpty
            ? l10n.dockerImagesEmpty
            : terms.isNotEmpty
            ? l10n.dockerImagesNoMatch
            : switch (_filter) {
                ImageFilter.unused => l10n.dockerImagesNoneUnused,
                ImageFilter.dangling => l10n.dockerImagesNoneDangling,
                // Every image passes; the engine listed none.
                ImageFilter.all => l10n.dockerImagesEmpty,
              },
      ),
    );
    if (!wide) {
      return _list(sortTableRows(entries, columns, _sort), columns, empty);
    }

    return SortableTable<ImageEntry>(
      tableId: DockerWatchList.images.name,
      columns: columns,
      rows: entries,
      rowKey: _rowKey,
      sort: _sort,
      onSort: (sort) => setState(() => _sort = sort),
      rowActions:
          actionsAllowedAt(
            context,
            widget.serverId,
            ActionEntryPoint.imageRemove,
          )
          ? (entry) => imageActionEntries(
              context,
              serverId: widget.serverId,
              entry: entry,
            )
          : null,
      empty: empty,
    );
  }

  Widget _filters(AppLocalizations l10n) => Wrap(
    spacing: 12,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: l10n.dockerImagesSearchHint,
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: l10n.dockerImagesSearchClear,
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(_search.clear),
                  ),
          ),
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final filter in ImageFilter.values)
            ChoiceChip(
              label: Text(switch (filter) {
                ImageFilter.all => l10n.dockerImagesFilterAll,
                ImageFilter.unused => l10n.dockerImagesFilterUnused,
                ImageFilter.dangling => l10n.dockerImagesFilterDangling,
              }),
              selected: _filter == filter,
              onSelected: (_) => setState(() => _filter = filter),
            ),
        ],
      ),
    ],
  );

  /// The phone layout's order: the table's columns in a menu, and the
  /// direction, which the button's tooltip names.
  Widget _sortControls(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final column = ImageColumn.values.byName(_sort.columnId);
    final ascending = _sort.direction == TableSortDirection.ascending;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          l10n.dockerImagesSortBy,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        DropdownButton<ImageColumn>(
          value: column,
          isDense: ghostIsDesktopPlatform(theme.platform),
          items: [
            for (final choice in ImageColumn.values)
              DropdownMenuItem(
                value: choice,
                child: Text(_label(l10n, choice)),
              ),
          ],
          onChanged: (choice) {
            if (choice == null) return;
            setState(
              () => _sort = TableSort(
                choice.name,
                _firstDirection.contains(choice)
                    ? TableSortDirection.descending
                    : TableSortDirection.ascending,
              ),
            );
          },
        ),
        IconButton(
          tooltip: ascending
              ? l10n.tableSortedAscending
              : l10n.tableSortedDescending,
          icon: Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward),
          onPressed: () => setState(
            () => _sort = TableSort(
              _sort.columnId,
              ascending
                  ? TableSortDirection.descending
                  : TableSortDirection.ascending,
            ),
          ),
        ),
      ],
    );
  }

  /// The phone layout: two-line rows that wrap at large text, the tags
  /// (or the dangling badge) over the other figures, each row one node
  /// naming its cells as the table's rows do.
  Widget _list(
    List<ImageEntry> entries,
    List<SortableTableColumn<ImageEntry>> columns,
    Widget empty,
  ) {
    if (entries.isEmpty) return empty;

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (context, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final cells = [
          for (final column in columns)
            (id: column.id, label: column.label, text: column.text(entry)),
        ];
        final tags = entry.tags;
        final row = Semantics(
          key: ValueKey(_phoneRowKey(entry)),
          container: true,
          label: [
            for (final cell in cells)
              l10n.tableCellSemantics(cell.label, cell.text),
          ].join('\n'),
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                if (tags.isEmpty)
                  const ImageDanglingBadge()
                else
                  Text(
                    imageTagsText(tags),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                Wrap(
                  spacing: 16,
                  runSpacing: 2,
                  children: [
                    // The tags head the row.
                    for (final cell in cells.skip(1))
                      Text(
                        l10n.dockerImagesFact(cell.label, cell.text),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
        // The actions sit beside the row's one node, so a screen reader
        // reaches them as a button of their own.
        return Row(
          children: [
            Expanded(child: row),
            ImageActionsButton(serverId: widget.serverId, entry: entry),
          ],
        );
      },
    );
  }

  List<SortableTableColumn<ImageEntry>> _columns(
    BuildContext context,
    AppLocalizations l10n,
    DateTime now,
  ) {
    final unknown = l10n.chartUnknownValue;

    /// [entry]'s age in words and its date, or null when unknown.
    (String, String)? created(ImageEntry entry) {
      final at = entry.image.created;
      if (at == null) return null;
      return (
        dockerAgeText(l10n, now.difference(at)),
        l10n.dockerImagesDate(at.toLocal()),
      );
    }

    return [
      SortableTableColumn(
        id: ImageColumn.tags.name,
        label: _label(l10n, ImageColumn.tags),
        text: (entry) => switch (entry.tags) {
          [] => l10n.dockerImagesDangling,
          final tags => imageTagsText(tags),
        },
        // Dangling images, which have no tag, sort last either way.
        sortKey: (entry) => switch (entry.tags) {
          [] => null,
          final tags => tags.first.toLowerCase(),
        },
        extent: const FlexColumnExtent(3),
        cell: (context, entry) => switch (entry.tags) {
          [] => const Align(
            alignment: AlignmentDirectional.centerStart,
            child: ImageDanglingBadge(),
          ),
          final tags => DockerCellText(text: imageTagsText(tags)),
        },
      ),
      SortableTableColumn(
        id: ImageColumn.id.name,
        label: _label(l10n, ImageColumn.id),
        text: (entry) => shortImageId(entry.image.id),
        sortKey: (entry) => bareImageId(entry.image.id),
        extent: const FixedColumnExtent(128),
      ),
      SortableTableColumn(
        id: ImageColumn.size.name,
        label: _label(l10n, ImageColumn.size),
        text: (entry) => switch (entry.image.size) {
          // IEC units (A11Y-06, 03 §10.10).
          final bytes? => ghostFormatBinarySize(bytes),
          null => unknown,
        },
        sortKey: (entry) => entry.image.size,
        firstDirection: TableSortDirection.descending,
        extent: const FixedColumnExtent(96),
        alignment: CellAlignment.end,
        cell: (context, entry) => DockerCellText(
          text: switch (entry.image.size) {
            final bytes? => ghostFormatBinarySize(bytes),
            null => unknown,
          },
          figure: true,
        ),
      ),
      SortableTableColumn(
        id: ImageColumn.created.name,
        label: _label(l10n, ImageColumn.created),
        text: (entry) => switch (created(entry)) {
          (final age, final date) => l10n.dockerImagesCreated(age, date),
          null => unknown,
        },
        sortKey: (entry) => entry.image.created?.millisecondsSinceEpoch,
        firstDirection: TableSortDirection.descending,
        extent: const FlexColumnExtent(2),
        cell: (context, entry) => switch (created(entry)) {
          (final age, final date) => DockerCreatedCell(age: age, date: date),
          null => DockerCellText(text: unknown),
        },
      ),
      SortableTableColumn(
        id: ImageColumn.use.name,
        label: _label(l10n, ImageColumn.use),
        text: (entry) => switch (entry.containers) {
          null => unknown,
          0 => l10n.dockerImagesUnused,
          final count => l10n.dockerImagesInUse(count),
        },
        sortKey: (entry) => entry.containers,
        extent: const FixedColumnExtent(128),
        cell: (context, entry) => switch (entry.containers) {
          null => DockerCellText(text: unknown),
          final count => DockerUseBadge(count: count),
        },
      ),
    ];
  }
}

/// The columns whose largest values matter, which start descending: the
/// biggest and the newest images first.
const _firstDirection = {ImageColumn.size, ImageColumn.created};

/// The key tests find a phone row by, in the table rows' form.
String _phoneRowKey(ImageEntry entry) =>
    '${DockerWatchList.images.name}.row.${_rowKey(entry)}';

/// A row's identity: the image's id.
Object _rowKey(ImageEntry entry) => entry.image.id;

String _label(AppLocalizations l10n, ImageColumn column) => switch (column) {
  ImageColumn.tags => l10n.dockerImagesColumnTags,
  ImageColumn.id => l10n.dockerImagesColumnId,
  ImageColumn.size => l10n.dockerImagesColumnSize,
  ImageColumn.created => l10n.dockerImagesColumnCreated,
  ImageColumn.use => l10n.dockerImagesColumnUse,
};

/// The mark of a dangling image, one without a tag (IMG-01): an icon and
/// its word in a tinted pill, so colour is never the only cue (A11Y-01).
class ImageDanglingBadge extends StatelessWidget {
  const ImageDanglingBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            Icon(
              Icons.label_off_outlined,
              size: 14,
              color: scheme.onTertiaryContainer,
            ),
            Flexible(
              child: Text(
                l10n.dockerImagesDangling,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
