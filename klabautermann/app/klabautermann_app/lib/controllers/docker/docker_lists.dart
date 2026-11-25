import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// What a server's container watch delivered (03 §7.12 CTR-01, CST-01).
@immutable
final class DockerContainerList {
  const DockerContainerList({
    this.containers,
    this.at,
    this.failure,
    this.stats = const {},
    this.statsFailure,
  });

  /// The latest list read, stopped containers too; null until one was.
  final List<ContainerSummary>? containers;

  /// When the engine read [containers], by this device's clock.
  final DateTime? at;

  /// Why the latest list read failed, or the engine refused the watch,
  /// while [containers] keeps the list before; null once one is read.
  final DockerQueryFailed? failure;

  /// Each listed container's latest list stats, by id. A container whose
  /// row left the screen keeps its last ones, which age by their
  /// [ContainerListStats.at].
  final Map<String, ContainerListStats> stats;

  /// Why the latest stats round failed; null once one succeeds.
  final DockerQueryFailed? statsFailure;

  DockerContainerList copyWith({
    DockerQueryFailed? Function()? failure,
    Map<String, ContainerListStats>? stats,
    DockerQueryFailed? Function()? statsFailure,
  }) => DockerContainerList(
    containers: containers,
    at: at,
    failure: failure == null ? this.failure : failure(),
    stats: stats ?? this.stats,
    statsFailure: statsFailure == null ? this.statsFailure : statsFailure(),
  );

  /// This list with [payload], a read of [list] at [at], taken in: a new
  /// list or stats round, or a failed one, which keeps what was read
  /// before. Lists other than the containers and their stats leave it as
  /// it was.
  DockerContainerList took(
    DockerWatchList list,
    DockerPayload payload,
    DateTime at,
  ) {
    switch ((list, payload)) {
      case (
        DockerWatchList.containers,
        DockerContainersPayload(:final containers),
      ):
        final ids = {for (final container in containers) container.id};
        return DockerContainerList(
          containers: containers,
          at: at,
          // Stats of a container that went go with it.
          stats: {
            for (final MapEntry(:key, :value) in stats.entries)
              if (ids.contains(key)) key: value,
          },
          statsFailure: statsFailure,
        );
      case (DockerWatchList.containers, final DockerQueryFailed failure):
        return copyWith(failure: () => failure);
      case (DockerWatchList.stats, DockerStatsPayload(:final stats)):
        return copyWith(
          stats: {...this.stats, for (final row in stats) row.containerId: row},
          statsFailure: () => null,
        );
      case (DockerWatchList.stats, final DockerQueryFailed failure):
        return copyWith(statsFailure: () => failure);
      default:
        return this;
    }
  }
}

/// What a server's list watch delivered (03 §7.14 IMG-01, §7.15 VOL-01,
/// DNW-01): the latest rows, when the engine read them, and why the latest
/// read failed while they keep the rows before.
///
/// The image, volume and network lists are this one shape; each names its
/// rows for its panel and says which payload fills it.
@immutable
abstract base class DockerWatchedList<T> {
  const DockerWatchedList({this.rows, this.at, this.failure});

  /// The latest list read; null until one was.
  final List<T>? rows;

  /// When the engine read [rows], by this device's clock.
  final DateTime? at;

  /// Why the latest read failed while [rows] keeps the list before; null
  /// once one is read.
  final DockerQueryFailed? failure;

  /// [payload]'s rows for this list, or null when it is not one.
  List<T>? rowsOf(DockerPayload payload);

  /// This list with [payload], read at [at], taken in: a failed read keeps
  /// the rows and says why, the payload's rows replace them, and any other
  /// payload leaves the list as it was.
  DockerWatchedList<T> took(DockerPayload payload, DateTime at) {
    if (payload case final DockerQueryFailed failure) return failed(failure);
    final next = rowsOf(payload);
    if (next == null) return this;
    return refilled(next, at);
  }

  /// This list keeping its rows and [at], with [failure] instead of its
  /// own.
  DockerWatchedList<T> failed(DockerQueryFailed failure);

  /// A list of [rows], read at [at], with no failure.
  DockerWatchedList<T> refilled(List<T> rows, DateTime at);
}

/// What a server's watches delivered of its images (03 §7.14 IMG-01).
@immutable
final class DockerImageList extends DockerWatchedList<ImageSummary> {
  const DockerImageList({super.rows, super.at, super.failure});

  /// The latest image list read; null until one was.
  List<ImageSummary>? get images => rows;

  @override
  List<ImageSummary>? rowsOf(DockerPayload payload) =>
      payload is DockerImagesPayload ? payload.images : null;

  @override
  DockerImageList took(DockerPayload payload, DateTime at) {
    final took = super.took(payload, at);
    return identical(took, this)
        ? this
        : DockerImageList(rows: took.rows, at: took.at, failure: took.failure);
  }

  @override
  DockerImageList failed(DockerQueryFailed failure) =>
      DockerImageList(rows: rows, at: at, failure: failure);

  @override
  DockerImageList refilled(List<ImageSummary> rows, DateTime at) =>
      DockerImageList(rows: rows, at: at);
}

/// What a server's watches delivered of its volumes (03 §7.15 VOL-01).
@immutable
final class DockerVolumeList extends DockerWatchedList<VolumeSummary> {
  const DockerVolumeList({super.rows, super.at, super.failure});

  /// The latest volume list read; null until one was.
  List<VolumeSummary>? get volumes => rows;

  @override
  List<VolumeSummary>? rowsOf(DockerPayload payload) =>
      payload is DockerVolumesPayload ? payload.volumes : null;

  @override
  DockerVolumeList took(DockerPayload payload, DateTime at) {
    final took = super.took(payload, at);
    return identical(took, this)
        ? this
        : DockerVolumeList(rows: took.rows, at: took.at, failure: took.failure);
  }

  @override
  DockerVolumeList failed(DockerQueryFailed failure) =>
      DockerVolumeList(rows: rows, at: at, failure: failure);

  @override
  DockerVolumeList refilled(List<VolumeSummary> rows, DateTime at) =>
      DockerVolumeList(rows: rows, at: at);
}

/// What a server's watches delivered of its networks (03 §7.15 DNW-01).
@immutable
final class DockerNetworkList extends DockerWatchedList<NetworkSummary> {
  const DockerNetworkList({super.rows, super.at, super.failure});

  /// The latest network list read; null until one was.
  List<NetworkSummary>? get networks => rows;

  @override
  List<NetworkSummary>? rowsOf(DockerPayload payload) =>
      payload is DockerNetworksPayload ? payload.networks : null;

  @override
  DockerNetworkList took(DockerPayload payload, DateTime at) {
    final took = super.took(payload, at);
    return identical(took, this)
        ? this
        : DockerNetworkList(
            rows: took.rows,
            at: took.at,
            failure: took.failure,
          );
  }

  @override
  DockerNetworkList failed(DockerQueryFailed failure) =>
      DockerNetworkList(rows: rows, at: at, failure: failure);

  @override
  DockerNetworkList refilled(List<NetworkSummary> rows, DateTime at) =>
      DockerNetworkList(rows: rows, at: at);
}

/// What a server's events watch delivered of the events timeline
/// (03 §7.12 DKE-03).
@immutable
final class DockerEventList {
  const DockerEventList({this.entries, this.failure});

  /// The timeline, oldest first; null until the watch delivered one.
  final List<DockerTimelineEntry>? entries;

  /// Why the watch failed while [entries] keeps the timeline before; null
  /// once one is delivered.
  final DockerQueryFailed? failure;

  /// This timeline with [payload] taken in.
  DockerEventList took(DockerPayload payload) => switch (payload) {
    DockerEventsPayload(:final entries) => DockerEventList(entries: entries),
    final DockerQueryFailed failure => DockerEventList(
      entries: entries,
      failure: failure,
    ),
    _ => this,
  };
}

/// A server's disk use measurement (02 OV-05): the last `/system/df`
/// read, and whether one is under way or why the last one failed.
@immutable
final class DockerDiskUse {
  const DockerDiskUse({
    this.df,
    this.at,
    this.inFlight = false,
    this.failure,
    this.socketPath,
  });

  /// The last measurement; null until one succeeded.
  final SystemDf? df;

  /// When [df] arrived, by this device's clock.
  final DateTime? at;

  /// Whether a measurement is under way.
  final bool inFlight;

  /// Why the latest measurement failed, while [df] keeps the one before;
  /// null once one succeeds.
  final DockerQueryFailed? failure;

  /// The engine socket [df] was read from: another engine's reading is
  /// dropped.
  final String? socketPath;

  /// This measurement with another under way over [socketPath]; the
  /// last failure is moot.
  DockerDiskUse measuring(String? socketPath) => DockerDiskUse(
    df: df,
    at: at,
    inFlight: true,
    socketPath: socketPath ?? this.socketPath,
  );

  /// This measurement with [payload], the answer that arrived at [now],
  /// taken in.
  DockerDiskUse took(DockerPayload payload, DateTime now) => switch (payload) {
    DockerSystemDfPayload(:final df) => DockerDiskUse(
      df: df,
      at: now,
      socketPath: socketPath,
    ),
    final DockerQueryFailed failure => DockerDiskUse(
      df: df,
      at: at,
      failure: failure,
      socketPath: socketPath,
    ),
    _ => DockerDiskUse(df: df, at: at, socketPath: socketPath),
  };
}

/// What a server's stack watch delivered (03 §7.16 STK-01, STK-05).
@immutable
final class DockerStackList {
  const DockerStackList({this.stacks, this.at, this.failure});

  /// The latest stacks read: the compose projects, each one's verdict
  /// and the compose CLI found; null until one was.
  final DockerStacksPayload? stacks;

  /// When the engine read [stacks], by this device's clock.
  final DateTime? at;

  /// Why the latest read failed, or the engine refused the watch, while
  /// [stacks] keeps the list before; null once one is read.
  final DockerQueryFailed? failure;

  /// This list with [payload], read at [at], taken in.
  DockerStackList took(DockerPayload payload, DateTime at) => switch (payload) {
    final DockerStacksPayload stacks => DockerStackList(stacks: stacks, at: at),
    final DockerQueryFailed failure => DockerStackList(
      stacks: stacks,
      at: this.at,
      failure: failure,
    ),
    _ => this,
  };
}

/// What a container's details view shows (03 §7.12 CTR-03, CTR-04).
@immutable
final class DockerContainerDetails {
  const DockerContainerDetails({
    this.container,
    this.failure,
    this.removed = false,
  });

  /// The latest inspect read, masked by the engine (03 §8.9); null until
  /// one was.
  final ContainerDetails? container;

  /// Why the latest inspect failed, while [container] keeps the one
  /// before; null once one is read.
  final DockerQueryFailed? failure;

  /// Whether the container is gone: a list no longer had it, or its
  /// inspect found nothing. [container] keeps what was read before.
  final bool removed;

  DockerContainerDetails copyWith({
    DockerQueryFailed? Function()? failure,
    bool? removed,
  }) => DockerContainerDetails(
    container: container,
    failure: failure == null ? this.failure : failure(),
    removed: removed ?? this.removed,
  );
}
