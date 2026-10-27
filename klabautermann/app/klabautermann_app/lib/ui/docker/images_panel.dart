import 'dart:async';

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
import '../charts/charts.dart' show ChartPalette;
import '../sortable_table.dart';
import 'image_history.dart';
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
/// id, size in IEC units, age and date of creation, whether any
/// container uses it and whether its registry has a newer digest
/// (IMG-05), a dangling one marked by word, with a filter for the
/// unused, the dangling or the updatable ones and a search by tag or ID.
///
/// While [visible], it holds the server's image watch
/// ([DockerController.watchImages]), which reads the containers too:
/// they tell which images are in use ([imageContainerCount]). Hidden, it
/// lets the watch go. A failed read keeps the last list under why it
/// failed. The ages follow the monitoring clock while the tab shows.
///
/// Each time it shows, it asks for the update check
/// ([DockerController.checkImageUpdates]); the engine reads a registry
/// again only for tags last read six hours ago, or on Check for updates.
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

  /// The update check's last answer, and why the last check failed if
  /// it did, for [ImagesPanel.serverId] (IMG-05).
  DockerImageUpdatesPayload? _updates;
  DockerQueryFailed? _updatesFailed;
  bool _checking = false;

  /// Counts the checks, so an answer for an earlier one is dropped.
  int _checks = 0;

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
      _updates = null;
      _updatesFailed = null;
      _checking = false;
      _checks++;
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
    _checkUpdates();
  }

  /// Asks for the update check; the caller rebuilds, as [_sync]'s do.
  void _checkUpdates({
    bool refresh = false,
    ImageCheckRunner runner = ImageCheckRunner.host,
  }) {
    final check = ++_checks;
    _checking = true;
    unawaited(
      _docker
          .checkImageUpdates(widget.serverId, refresh: refresh, runner: runner)
          .then((answer) {
            if (!mounted || check != _checks) return;

            setState(() {
              _checking = false;
              switch (answer) {
                case DockerImageUpdatesPayload():
                  _updates = answer;
                  _updatesFailed = null;
                case DockerQueryFailed():
                  _updatesFailed = answer;
                default:
                  // The engine answers this query with one of the two.
                  _updatesFailed = const DockerQueryFailed(
                    DockerQueryFailure.daemonError,
                  );
              }
            });
          }),
    );
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
            if (images != null) ..._updateNotices(context, l10n),
            if (images != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // Pull and prune share the server's action policy;
                    // the update check only reads.
                    if (actionsAllowedAt(
                      context,
                      widget.serverId,
                      ActionEntryPoint.prune,
                    )) ...[
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
                    OutlinedButton.icon(
                      onPressed: _checking
                          ? null
                          : () => setState(() => _checkUpdates(refresh: true)),
                      // A still icon: a check can wait minutes on a slow
                      // registry, and the label already says it runs.
                      icon: Icon(
                        _checking ? Icons.hourglass_empty : Icons.update,
                      ),
                      label: Text(
                        _checking
                            ? l10n.dockerImagesUpdatesChecking
                            : l10n.dockerImagesUpdatesCheck,
                      ),
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
      updates: {
        for (final row in _updates?.rows ?? const <ImageUpdateRow>[])
          row.reference: row,
      },
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
                ImageFilter.updates => l10n.dockerImagesNoneUpdates,
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
      onRowActivated: (entry) => _openHistory(entry.image),
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
                ImageFilter.updates => l10n.dockerImagesFilterUpdates,
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

  /// Why the update check could not run or skipped some tags (IMG-05,
  /// D68): a failed check, a host without curl, which offers the
  /// daemon's DistributionInspect with what it costs, and Docker Hub's
  /// spent quota with when the check reads it again.
  List<Widget> _updateNotices(BuildContext context, AppLocalizations l10n) {
    final failed = _updatesFailed;
    if (failed != null) {
      return [
        DockerNotice(
          icon: Icons.error_outline,
          text: l10n.dockerImagesUpdatesFailed(failed.failure.name),
          detail: failed.detail,
          action: TextButton(
            onPressed: _checking ? null : () => setState(_checkUpdates),
            child: Text(l10n.dockerRetry),
          ),
        ),
      ];
    }

    final updates = _updates;
    if (updates == null) return const [];

    DateTime? resumes;
    for (final row in updates.rows) {
      if (row.comparison.issue != ImageUpdateIssue.rateLimited) continue;
      final at = row.checkedAt.add(
        row.rateLimit?.window ?? kImageUpdateBackoff,
      );
      if (resumes == null || at.isAfter(resumes)) resumes = at;
    }
    return [
      if (updates.curlMissing)
        DockerNotice(
          icon: Icons.cloud_off_outlined,
          text: l10n.dockerImagesUpdatesNoCurl,
          action: TextButton(
            onPressed: _checking
                ? null
                : () => setState(
                    () => _checkUpdates(
                      refresh: true,
                      runner: ImageCheckRunner.daemon,
                    ),
                  ),
            child: Text(l10n.dockerImagesUpdatesThroughDaemon),
          ),
        ),
      if (resumes != null)
        DockerNotice(
          icon: Icons.hourglass_bottom,
          text: l10n.dockerImagesUpdatesRateLimited(
            MaterialLocalizations.of(
              context,
            ).formatTimeOfDay(TimeOfDay.fromDateTime(resumes.toLocal())),
          ),
        ),
    ];
  }

  /// Opens [image]'s history (IMG-04), a read that needs no actions.
  void _openHistory(ImageSummary image) => openImageHistory(
    context,
    monitoring: widget.monitoring,
    serverId: widget.serverId,
    image: image,
  );

  /// The phone layout: two-line rows that wrap at large text, the tags
  /// (or the dangling badge) over the other figures, each row one node
  /// naming its cells as the table's rows do. A tap opens the image's
  /// history.
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
          button: true,
          label: [
            for (final cell in cells)
              l10n.tableCellSemantics(cell.label, cell.text),
          ].join('\n'),
          excludeSemantics: true,
          onTap: () => _openHistory(entry.image),
          child: InkWell(
            excludeFromSemantics: true,
            onTap: () => _openHistory(entry.image),
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
      SortableTableColumn(
        id: ImageColumn.update.name,
        label: _label(l10n, ImageColumn.update),
        text: (entry) => imageUpdateText(l10n, entry),
        // Updates first, then the undecided, then the current; images
        // not checked yet sort last either way.
        sortKey: (entry) => switch (entry.update) {
          ImageUpdateStatus.updateAvailable => 0,
          ImageUpdateStatus.unknown => 1,
          ImageUpdateStatus.upToDate => 2,
          null => null,
        },
        extent: const FixedColumnExtent(168),
        cell: (context, entry) => ImageUpdateBadge(entry: entry),
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
  ImageColumn.update => l10n.dockerImagesColumnUpdate,
};

/// What the update check says of [entry] in words (IMG-05), with why
/// when it could not decide.
String imageUpdateText(AppLocalizations l10n, ImageEntry entry) =>
    switch (entry.update) {
      null => l10n.dockerImagesUpdateNotChecked,
      ImageUpdateStatus.updateAvailable => l10n.dockerImagesUpdateAvailable,
      ImageUpdateStatus.upToDate => l10n.dockerImagesUpdateCurrent,
      ImageUpdateStatus.unknown => l10n.dockerImagesUpdateUnknown(
        _undecidedReason(l10n, entry),
      ),
    };

/// Why the first undecided tag of [entry] could not be compared.
String _undecidedReason(AppLocalizations l10n, ImageEntry entry) {
  final row = entry.updates.firstWhere(
    (row) => row.comparison.status == ImageUpdateStatus.unknown,
  );
  if (row.cliMissing) return l10n.dockerImagesUpdateWhyNoBuildx;
  return l10n.dockerImagesUpdateWhy(
    (row.comparison.issue ?? ImageUpdateIssue.noResult).name,
  );
}

/// The update check's mark for one image (IMG-05): an icon and its word,
/// amber for an update, so colour is never the only cue (A11Y-01). The
/// tooltip says why an undecided one could not be compared.
class ImageUpdateBadge extends StatelessWidget {
  const ImageUpdateBadge({super.key, required this.entry});

  final ImageEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final (icon, color, label) = switch (entry.update) {
      null => (Icons.remove, muted, l10n.dockerImagesUpdateNotChecked),
      ImageUpdateStatus.updateAvailable => (
        Icons.upgrade,
        ChartPalette.of(context).warning,
        l10n.dockerImagesUpdateAvailable,
      ),
      ImageUpdateStatus.upToDate => (
        Icons.check,
        muted,
        l10n.dockerImagesUpdateCurrent,
      ),
      ImageUpdateStatus.unknown => (
        Icons.help_outline,
        muted,
        l10n.dockerImagesUpdateUndecided,
      ),
    };
    final badge = Row(
      spacing: 4,
      children: [
        Icon(icon, size: 14, color: color),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: entry.update == ImageUpdateStatus.updateAvailable
                  ? color
                  : muted,
            ),
          ),
        ),
      ],
    );
    if (entry.update != ImageUpdateStatus.unknown) return badge;

    return Tooltip(message: imageUpdateText(l10n, entry), child: badge);
  }
}

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
