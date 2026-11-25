// A masked process argument (03 §8.9): its display and toString carry the
// mask, so the app shows a secret only through the reveal action. The
// Docker models are plain data too: no field holds a function, and the
// engine masks the ones that could hold a secret before they cross.
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show
        ComposeGrouping,
        ContainerHostConfig,
        ContainerMount,
        ContainerNetworkSettings,
        ContainerSummary,
        DockerServerVersion,
        EngineInfo,
        EnvVar,
        ExternalManager,
        HealthStatus,
        ImageDigestComparison,
        ImageSummary,
        MaskedValue,
        NetworkSummary,
        RegistryRateLimit,
        SystemDf,
        VolumeSummary;
import 'package:klabautermann_host/klabautermann_host.dart'
    show EngineMode, EngineRuntime;
import 'package:meta/meta.dart';

import '../../docker/docker_ladder.dart' show DockerRank, DockerRootEquivalence;
import '../../docker/dropbear.dart' show DropbearRelease;

/// What a [DockerQuery] reads (03 §7.12 to §7.14).
@immutable
sealed class DockerQuerySpec {
  const DockerQuerySpec();
}

/// The engine panel (DKE-01): `/info`, with the `/version` the endpoint
/// negotiated over. Answered by [DockerEnginePayload].
final class DockerEngineQuery extends DockerQuerySpec {
  const DockerEngineQuery();
}

/// Every container, stopped ones too (CTR-01). Answered by
/// [DockerContainersPayload].
final class DockerContainersQuery extends DockerQuerySpec {
  const DockerContainersQuery();
}

/// One container's inspect (CTR-03, CTR-04). Answered by
/// [DockerContainerPayload].
final class DockerContainerQuery extends DockerQuerySpec {
  const DockerContainerQuery(this.containerId);

  /// The container's id or name.
  final String containerId;
}

/// One running container's processes (CTR-10). Answered by
/// [DockerContainerTopPayload]; the daemon refuses a container that is
/// not running (409), which answers [DockerQueryFailed] with
/// `daemonError`.
final class DockerContainerTopQuery extends DockerQuerySpec {
  const DockerContainerTopQuery(this.containerId);

  /// The container's id or name.
  final String containerId;
}

/// The image list (IMG-01). Answered by [DockerImagesPayload].
final class DockerImagesQuery extends DockerQuerySpec {
  const DockerImagesQuery();
}

/// One image's layers (IMG-04). Answered by [DockerImageHistoryPayload].
final class DockerImageHistoryQuery extends DockerQuerySpec {
  const DockerImageHistoryQuery(this.image);

  /// The image's id, or a tag of it.
  final String image;
}

/// IMG-05's digest update check for every tagged image (D68): rows read
/// within six hours are kept unless [refresh]. Answered by
/// [DockerImageUpdatesPayload].
final class DockerImageUpdatesQuery extends DockerQuerySpec {
  const DockerImageUpdatesQuery({
    this.refresh = false,
    this.runner = ImageCheckRunner.host,
  });

  /// Reads every reference again, as the Check now action does.
  final bool refresh;

  /// Where the registry reads run.
  final ImageCheckRunner runner;
}

/// Where an update check's registry reads run (D68).
enum ImageCheckRunner {
  /// curl on the host, buildx where the registry wants credentials: no
  /// Docker Hub pull is spent.
  host,

  /// The daemon's DistributionInspect, which spends a Docker Hub pull per
  /// tag: the last resort, asked for only when the host has no curl and
  /// the person accepts that cost.
  daemon,
}

/// Disk use by type (02 OV-05): `/system/df` without `verbose`, which
/// the daemon computes by walking images, containers, volumes and the
/// build cache, so the app asks for it only on demand. Answered by
/// [DockerSystemDfPayload].
final class DockerSystemDfQuery extends DockerQuerySpec {
  const DockerSystemDfQuery();
}

/// DKE-06's security review and DKE-07's log rotation lint, on demand:
/// the list, then an inspect of each container, up to
/// [kDockerReviewMax]. Answered by [DockerReviewPayload].
final class DockerReviewQuery extends DockerQuerySpec {
  const DockerReviewQuery();
}

/// One file of the compose project [project] (03 §7.16 STK-04, M11):
/// a config file or an environment file its containers recorded, or the
/// `.env` in its working directory, read over SFTP once the project's
/// source is verified. Answered by [DockerStackFilePayload] or
/// [DockerStackFileFailed].
final class DockerStackFileQuery extends DockerQuerySpec {
  const DockerStackFileQuery({required this.project, required this.path});

  /// The compose project name.
  final String project;

  /// The file's absolute path, as the project's labels name it.
  final String path;
}

/// The profiles a verified project's files name (03 §7.16 STK-09), for
/// STK-23's `--profile` choices: `compose config --profiles`. Answered
/// by [DockerStackProfilesPayload], by [DockerStackFileFailed] when the
/// project is unknown or unverified, or by [DockerQueryFailed] when the
/// CLI could not list them.
final class DockerStackProfilesQuery extends DockerQuerySpec {
  const DockerStackProfilesQuery(this.project);

  final String project;
}

/// The compose files in [directories] and the folders right below them
/// (03 §7.16 STK-08): `find <dir> -maxdepth 2` for `compose*.y*ml` and
/// `docker-compose*.y*ml`, run as the login user, for stacks with no
/// containers. Answered by [DockerStackScanPayload].
final class DockerStackScanQuery extends DockerQuerySpec {
  DockerStackScanQuery(Iterable<String> directories)
    : directories = List.unmodifiable(directories);

  /// Absolute paths, at most [kStackScanDirectoriesMax].
  final List<String> directories;
}

/// The most folders one [DockerStackScanQuery] searches [E].
const int kStackScanDirectoriesMax = 16;

/// The compose CLIs on the server (03 §7.16 STK-05), for the Access tab's
/// compose row (CN-24) without a stacks watch: looked for once per
/// endpoint in one exec, as stack verification does. Answered by
/// [DockerComposePayload].
final class DockerComposeQuery extends DockerQuerySpec {
  const DockerComposeQuery();
}

/// A list a [DockerWatch] follows (03 §7.12 to §7.14).
enum DockerWatchList {
  /// Every container (CTR-01), as [DockerContainersPayload].
  containers,

  /// The image list (IMG-01), as [DockerImagesPayload].
  images,

  /// The containers grouped by compose project (STK-01), as
  /// [DockerStacksPayload].
  stacks,

  /// One-shot stats for the watch's `statsFor` (CST-01), as
  /// [DockerStatsPayload].
  stats,

  /// The volume list (03 §7.15 VOL-01), as [DockerVolumesPayload].
  volumes,

  /// The network list (03 §7.15 DNW-01), as [DockerNetworksPayload].
  networks,

  /// The engine's events while the app follows them (03 §7.12 DKE-03),
  /// as [DockerEventsPayload].
  events,
}

/// The most watches one server holds [E]: a Docker view holds one or two.
const kDockerWatchesMax = 16;

/// The most containers one watch reads stats for [E]: more rows than a
/// screen shows.
const kDockerStatsForMax = 64;

/// What a [DockerResult] or [DockerListChanged] carries.
@immutable
sealed class DockerPayload {
  const DockerPayload();
}

/// The engine's `/info` and `/version` (DKE-01).
final class DockerEnginePayload extends DockerPayload {
  const DockerEnginePayload(this.info, this.version);

  final EngineInfo info;
  final DockerServerVersion version;
}

/// The container list (CTR-01), labels masked by key. Each
/// [ContainerSummary.command] is null: the list's command line can hold
/// a secret, and [ContainerDetails] carries it masked (03 §8.9).
final class DockerContainersPayload extends DockerPayload {
  const DockerContainersPayload(this.containers);

  final List<ContainerSummary> containers;
}

/// One inspected container, masked (03 §8.9).
final class DockerContainerPayload extends DockerPayload {
  const DockerContainerPayload(this.container);

  final ContainerDetails container;
}

/// An image's layers, newest first (IMG-04), each layer's instruction
/// masked as a command line is (03 §8.9): a build argument or a secret
/// assignment in it crosses only behind [MaskedValue].
final class DockerImageHistoryPayload extends DockerPayload {
  DockerImageHistoryPayload(Iterable<ImageLayer> layers)
    : layers = List.unmodifiable(layers);

  final List<ImageLayer> layers;
}

/// A container's processes (CTR-10): the columns `ps` named and a row
/// per process, the command line column masked as Processes masks one
/// (03 §8.9).
final class DockerContainerTopPayload extends DockerPayload {
  DockerContainerTopPayload({
    required Iterable<String> titles,
    required Iterable<List<MaskedValue>> processes,
    this.commandColumn,
  }) : titles = List.unmodifiable(titles),
       processes = List.unmodifiable([
         for (final row in processes) List<MaskedValue>.unmodifiable(row),
       ]);

  final List<String> titles;

  /// One cell per title; only the command line's can be masked.
  final List<List<MaskedValue>> processes;

  /// The index of the command line's title, or null where `ps` named
  /// none (a Windows daemon lists the image name instead).
  final int? commandColumn;
}

/// One layer of an image's history (IMG-04).
@immutable
final class ImageLayer {
  const ImageLayer({
    required this.createdBy,
    this.id,
    this.created,
    this.size,
    this.comment,
    this.tags = const [],
  });

  /// The image id at this layer, or null for one built elsewhere.
  final String? id;
  final DateTime? created;

  /// The instruction that made the layer, masked.
  final MaskedValue createdBy;
  final int? size;
  final String? comment;
  final List<String> tags;
}

/// How an update check read the registry digest (D68).
enum ImageUpdateRoute {
  /// A manifest `HEAD` by curl on the host.
  registry,

  /// `docker buildx imagetools inspect` with the host CLI's credentials.
  hostCli,

  /// The daemon's DistributionInspect ([ImageCheckRunner.daemon]).
  daemon,
}

/// One reference's update check (IMG-05).
@immutable
final class ImageUpdateRow {
  const ImageUpdateRow({
    required this.reference,
    required this.imageId,
    required this.comparison,
    required this.checkedAt,
    this.route,
    this.cliMissing = false,
    this.rateLimit,
  });

  /// The tag as the image list names it, e.g. `alpine:3.22`.
  final String reference;
  final String imageId;
  final ImageDigestComparison comparison;
  final DateTime checkedAt;

  /// Null when no digest came back.
  final ImageUpdateRoute? route;

  /// The registry wants credentials and the host has no buildx plugin.
  final bool cliMissing;

  /// Docker Hub's count for the host's address, when it sent one.
  final RegistryRateLimit? rateLimit;
}

/// The update check (IMG-05): a row per tagged image that has been
/// checked, fresh or kept from an earlier check.
final class DockerImageUpdatesPayload extends DockerPayload {
  DockerImageUpdatesPayload(
    Iterable<ImageUpdateRow> rows, {
    this.curlMissing = false,
  }) : rows = List.unmodifiable(rows);

  final List<ImageUpdateRow> rows;

  /// The host has no `curl`, so this check read no registry.
  final bool curlMissing;
}

/// The image list (IMG-01), labels masked by key.
final class DockerImagesPayload extends DockerPayload {
  const DockerImagesPayload(this.images);

  final List<ImageSummary> images;
}

/// The volume list (03 §7.15 VOL-01), labels masked by key.
final class DockerVolumesPayload extends DockerPayload {
  const DockerVolumesPayload(this.volumes);

  final List<VolumeSummary> volumes;
}

/// The network list (03 §7.15 DNW-01), labels masked by key.
final class DockerNetworksPayload extends DockerPayload {
  const DockerNetworksPayload(this.networks);

  final List<NetworkSummary> networks;
}

/// The events timeline (DKE-03): the newest `kDockerEventsKept` entries,
/// oldest first, events and the gaps between streams alike.
final class DockerEventsPayload extends DockerPayload {
  DockerEventsPayload(Iterable<DockerTimelineEntry> entries)
    : entries = List.unmodifiable(entries);

  final List<DockerTimelineEntry> entries;
}

/// One line of the events timeline.
@immutable
sealed class DockerTimelineEntry {
  const DockerTimelineEntry(this.at);

  /// When it happened, in UTC: the event's time, or when a gap began.
  final DateTime at;
}

/// One engine event.
final class DockerTimelineEvent extends DockerTimelineEntry {
  const DockerTimelineEvent({
    required DateTime at,
    required this.type,
    required this.action,
    this.actorId,
    this.name,
    this.image,
    this.exitCode,
  }) : super(at);

  /// `container`, `image`, `volume` or `network`.
  final String type;

  /// `start`, `die`, `health_status: unhealthy`, `pull`, ...
  final String action;
  final String? actorId;

  /// The container's, volume's or network's name; an image's reference.
  final String? name;

  /// A container's image.
  final String? image;

  /// A container's exit code, on `die`.
  final int? exitCode;
}

/// A span the app did not follow the events: the stream was lost from
/// [at] until [until]. With [resumed] the stream asked the engine for the
/// events of the span, which it keeps only in a bounded buffer; without
/// it the span's events are not shown.
final class DockerTimelineGap extends DockerTimelineEntry {
  const DockerTimelineGap({
    required DateTime at,
    required this.until,
    required this.resumed,
  }) : super(at);

  final DateTime until;
  final bool resumed;
}

/// `/system/df`'s totals per type (02 OV-05), read in the shape the
/// negotiated version gates; a type the daemon did not cover is null.
final class DockerSystemDfPayload extends DockerPayload {
  const DockerSystemDfPayload(this.df);

  final SystemDf df;
}

/// The most containers a [DockerReviewQuery] inspects, one request
/// each; the rest are counted in [DockerReviewPayload.omitted].
const kDockerReviewMax = 200;

/// What DKE-06 and DKE-07 flag in a container's configuration, from
/// the most to the least severe.
enum ContainerRisk {
  /// `HostConfig.Privileged`: every device and capability of the host.
  privileged,

  /// An engine socket bind-mounted in, which is root on the host
  /// (03 §8.1), or a host folder that holds one (`/`, `/run`,
  /// `/var/run`); its path is the finding's detail.
  socketMount,

  /// `NetworkMode` host.
  hostNetwork,

  /// `PidMode` host.
  hostPid,

  /// `CapAdd`; the capabilities are the detail.
  addedCapabilities,

  /// A database's port published on every address; the port is the
  /// detail.
  databasePublished,

  /// No `User`, or root, on an engine that maps neither (rootless or a
  /// user namespace remap).
  rootUser,

  /// The `json-file` log driver without `max-size`, which never rotates
  /// (r5 §1.6).
  logsUnrotated,

  /// An image named without a tag or digest, or by `latest`; the
  /// reference is the detail.
  latestTag,

  /// No health check from the image or the container, or one turned
  /// off.
  noHealthcheck,

  /// Restart policy `no`, on a container that is not removed when it
  /// stops and not a compose one-off run.
  noRestartPolicy;

  /// How much the risk matters: [ContainerRiskLevel.high] where the
  /// container can take the host, [ContainerRiskLevel.medium] where it
  /// widens what a break-in reaches or fills the disk.
  ContainerRiskLevel get level => switch (this) {
    privileged ||
    socketMount ||
    hostNetwork ||
    hostPid ||
    addedCapabilities ||
    databasePublished => ContainerRiskLevel.high,
    rootUser || logsUnrotated => ContainerRiskLevel.medium,
    latestTag || noHealthcheck || noRestartPolicy => ContainerRiskLevel.low,
  };
}

enum ContainerRiskLevel { high, medium, low }

/// One [ContainerRisk] a container carries, with what it names: a path,
/// capabilities, a port or an image reference.
@immutable
final class ContainerFinding {
  const ContainerFinding(this.risk, {this.detail});

  final ContainerRisk risk;
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is ContainerFinding && other.risk == risk && other.detail == detail;

  @override
  int get hashCode => Object.hash(risk, detail);

  @override
  String toString() => 'ContainerFinding($risk, $detail)';
}

/// One container's review: its findings, most severe first, empty when
/// it carries none.
@immutable
final class ContainerReview {
  const ContainerReview({
    required this.containerId,
    required this.name,
    required this.state,
    this.project,
    required this.findings,
  });

  final String containerId;
  final String name;

  /// The list's `State`, such as `running` or `exited`.
  final String? state;

  /// The compose project, when the container belongs to one.
  final String? project;

  final List<ContainerFinding> findings;
}

/// Another manager, monitor or log viewer DKE-17 recognises among the
/// containers by its image.
enum HostTool {
  portainer,
  dockhand,
  dockge,
  dozzle,
  beszel,
  uptimeKuma,
  netdata,
  wud,
}

/// One container running a [HostTool], with its published ports as the
/// list labels them (`0.0.0.0:9443->9443/tcp`).
@immutable
final class HostToolContainer {
  const HostToolContainer({
    required this.tool,
    required this.containerId,
    required this.name,
    required this.state,
    this.ports = const [],
  });

  final HostTool tool;
  final String containerId;
  final String name;
  final String? state;
  final List<String> ports;
}

/// A [DockerReviewQuery]'s answer: each container read, in the list's
/// order, and the other tools running among all of them (DKE-17). A
/// container removed between the list and its inspect is left out;
/// [omitted] counts those past [kDockerReviewMax], [unreadable] those
/// whose inspect the daemon refused.
final class DockerReviewPayload extends DockerPayload {
  const DockerReviewPayload(
    this.reviews, {
    this.omitted = 0,
    this.unreadable = 0,
    this.tools = const [],
  });

  final List<ContainerReview> reviews;
  final int omitted;
  final int unreadable;
  final List<HostToolContainer> tools;
}

/// The containers grouped by compose project (STK-01), from the same
/// list [DockerContainersPayload] carries, with each project's source
/// verdict and the compose CLI the host has (STK-05). A project's
/// managed-by badge (STK-10) is its [ComposeProject.ownership].
final class DockerStacksPayload extends DockerPayload {
  const DockerStacksPayload(
    this.grouping, {
    this.verdicts = const {},
    this.composeCli,
  });

  final ComposeGrouping grouping;

  /// The verdict for each project in [grouping], by name; a project the
  /// engine has not checked yet reads [StackVerifying], and the list is
  /// sent again once it has.
  final Map<String, StackVerdict> verdicts;

  /// The compose CLI found, once the engine has looked.
  final DockerComposeCli? composeCli;
}

/// The compose CLIs a [DockerComposeQuery] found.
final class DockerComposePayload extends DockerPayload {
  const DockerComposePayload(this.composeCli);

  final DockerComposeCli composeCli;
}

/// Whether a compose project's files are its source (03 §7.16 STK-01).
@immutable
sealed class StackVerdict {
  const StackVerdict();
}

/// The engine is checking the project's files, or waits to: [waiting]
/// says why a check could not start yet.
final class StackVerifying extends StackVerdict {
  const StackVerifying({this.waiting});

  final StackWait? waiting;
}

/// Why a stack check has not started (M4 plan M6).
enum StackWait {
  /// The link has no session channel left at its learned limit: the
  /// samplers hold them, and a background check does not borrow one.
  channel,
}

/// Every config file exists and `compose config --hash '*'` over them
/// matches the `config-hash` label of every service's containers: the
/// files are the project's source.
final class StackVerified extends StackVerdict {
  const StackVerified();
}

/// "Unverified source", for [reason].
final class StackUnverified extends StackVerdict {
  const StackUnverified(this.reason);

  final StackUnverifiedReason reason;
}

/// "Source not on host": a config file the containers name is missing.
/// A manager that runs compose in its own container records paths
/// inside it (Dockge's rule), so [deployedBy] names the manager the
/// project's labels mark, when they mark one.
final class StackSourceNotOnHost extends StackVerdict {
  const StackSourceNotOnHost({this.deployedBy});

  final ExternalManager? deployedBy;
}

/// Why a project's files are not its verified source.
enum StackUnverifiedReason {
  /// The containers record no config files.
  noSourceLabels,

  /// A recorded project name or path fails 03 §8.8's validation, so no
  /// command names it.
  unsafeLabels,

  /// A service's container carries no `config-hash` label.
  noHashLabels,

  /// The host has no compose CLI.
  noComposeCli,

  /// The host has only the standalone `docker-compose`, which is
  /// read-only (STK-05) and does not verify.
  standaloneComposeOnly,

  /// The compose CLI did not print service hashes for `config --hash
  /// '*'`, as one without that flag form would not.
  cliCouldNotHash,

  /// `compose config` failed over the files: a file it cannot read or
  /// parse, or a variable it cannot interpolate.
  configFailed,

  /// A service's hash differs from its containers' label, or the files
  /// define no such service: the files changed since the deploy, or
  /// are not the ones it used.
  hashMismatch,

  /// The check could not run: the link failed or timed out.
  checkFailed,
}

/// The compose CLIs on the host (03 §7.16 STK-05), each version as it
/// printed it without a leading `v`.
@immutable
final class DockerComposeCli {
  const DockerComposeCli({this.pluginVersion, this.standaloneVersion});

  /// `docker compose version`; null without the plugin.
  final String? pluginVersion;

  /// `docker-compose version`; null without the standalone binary.
  final String? standaloneVersion;

  /// Whether the standalone binary is the Python Compose v1, unmaintained
  /// since 2023 and read-only here (STK-05).
  bool get standaloneLegacy => standaloneVersion?.startsWith('1.') ?? false;
}

/// One stack file (03 §7.16 STK-04, M11) as spans whose
/// [MaskedValue.display]s joined are the file with its secrets masked
/// (03 §8.9); the app reveals one span at a time. Read fresh for each
/// query, and never cached or logged by the engine.
final class DockerStackFilePayload extends DockerPayload {
  const DockerStackFilePayload({
    required this.project,
    required this.path,
    required this.text,
    required this.size,
    this.truncated = false,
  });

  final String project;
  final String path;
  final List<MaskedValue> text;

  /// The file's size in bytes, as SFTP reported it.
  final int size;

  /// Whether the file is over [kStackFileMaxBytes], so [text] holds only
  /// its complete lines within that many bytes.
  final bool truncated;
}

/// The profiles a [DockerStackProfilesQuery] found, sorted.
final class DockerStackProfilesPayload extends DockerPayload {
  DockerStackProfilesPayload({
    required this.project,
    required Iterable<String> profiles,
  }) : profiles = List.unmodifiable(profiles);

  final String project;
  final List<String> profiles;
}

/// The compose files a [DockerStackScanQuery] found, sorted.
final class DockerStackScanPayload extends DockerPayload {
  DockerStackScanPayload(Iterable<String> files, {this.incomplete = false})
    : files = List.unmodifiable(files);

  /// Absolute paths; a stack's folder is a file's directory.
  final List<String> files;

  /// Whether a folder could not be read, or the list was cut at the
  /// output cap, so stacks may be missing.
  final bool incomplete;
}

/// The most bytes of a stack file the engine reads (M11 [E]).
const kStackFileMaxBytes = 1024 * 1024;

/// A [DockerStackFileQuery] the engine did not answer with the file.
final class DockerStackFileFailed extends DockerPayload {
  const DockerStackFileFailed(this.failure);

  final StackFileFailure failure;
}

/// Why a [DockerStackFileQuery] read no file.
enum StackFileFailure {
  /// No container belongs to the project.
  unknownStack,

  /// The project's source is not verified ([StackVerdict]).
  notVerified,

  /// The path is none of the project's files.
  notStackFile,

  /// SFTP found no file at the path.
  notFound,

  /// The login user cannot read the file; admin mode's elevated read
  /// arrives with M4.
  permissionDenied,

  /// The path is a symbolic link, directory or other non-regular file.
  notRegularFile,

  /// SFTP failed, or the file changed while it was read.
  readFailed,
}

/// One stats round over a watch's `statsFor` (CST-01): a row for each
/// running container that answered, in no set order.
final class DockerStatsPayload extends DockerPayload {
  const DockerStatsPayload(this.stats);

  final List<ContainerListStats> stats;
}

/// One container's list stats (03 §7.12 CST-01), read at [at] by the
/// engine's clock.
@immutable
final class ContainerListStats {
  const ContainerListStats({
    required this.containerId,
    required this.at,
    this.cpuPercent,
    this.memoryUsed,
    this.memoryLimit,
    this.networkRx,
    this.networkTx,
    this.blockRead,
    this.blockWrite,
    this.pids,
  });

  final String containerId;
  final DateTime at;

  /// CPU % by the spec formula over the time since the previous read,
  /// so null on a container's first one, on the first after a read of it
  /// failed, and on the first after a [DockerListChanged.fullRelist]
  /// (one-shot `precpu_stats` is not meaningful, 03 §5.6).
  final double? cpuPercent;

  /// Bytes in use less `inactive_file` (cgroup v2) or the cache (v1).
  final int? memoryUsed;
  final int? memoryLimit;

  /// Bytes received and sent over every interface since the container
  /// started (CTR-08), as `docker stats` totals them; null when the
  /// container has no network or the daemon reported none.
  final int? networkRx;
  final int? networkTx;

  /// Bytes read and written on block devices since it started; null
  /// where the cgroup reports no I/O accounting (`blkio_stats` empty, as
  /// on some cgroup v2 hosts).
  final int? blockRead;
  final int? blockWrite;

  /// The processes and threads in its cgroup.
  final int? pids;
}

/// The query read nothing, for [failure]; [detail] is the daemon's own
/// message or the transport error, for diagnostics.
final class DockerQueryFailed extends DockerPayload {
  const DockerQueryFailed(this.failure, {this.detail});

  final DockerQueryFailure failure;
  final String? detail;
}

/// Why a [DockerQuery] or a watched list read nothing.
enum DockerQueryFailure {
  /// The server is not in the fleet.
  notInFleet,

  /// The server has no ready link.
  linkUnavailable,

  /// The server's capability probe has not answered on this link, so
  /// the engine cannot look for its sockets yet (03 §5.4).
  profileUnknown,

  /// The endpoint failed; its [DockerEndpointState] says why. A later
  /// query looks for it again.
  endpointUnavailable,

  /// The server already holds the most queries waiting for its endpoint,
  /// or the most watches.
  tooManyQueries,

  /// The query names no container, or the watch names more stats
  /// containers than [kDockerStatsForMax].
  invalidQuery,

  /// The object is gone (404); a list query shows what remains.
  notFound,

  /// The daemon refused or failed the call.
  daemonError,

  /// The connection to the daemon failed, timed out or carried malformed
  /// HTTP, or a command the query runs on the server failed.
  connectionFailed,

  /// The endpoint closed before the query ran: its link went, the app
  /// disconnected, or the server left the fleet or changed endpoint.
  cancelled,
}

/// Where a [DockerEndpointState] is.
enum DockerEndpointPhase {
  /// The server has no ready link, or its capability probe has not
  /// answered on it.
  waiting,

  /// The engine runs the ladder and negotiates over the route found.
  resolving,

  /// Queries run over the route.
  ready,

  /// No route reached an engine that answers with an API version this
  /// client takes.
  failed,
}

/// Why a [DockerEndpointState] failed.
enum DockerEndpointFailure {
  /// No rung reached an engine socket (03 §5.9).
  noRoute,

  /// Routes opened, but the engine answered `_ping` and `/version` over
  /// none of them.
  unreachable,

  /// The engine's newest API version is below the client floor 1.41
  /// (03 §5.8).
  belowClientFloor,

  /// The engine's `MinAPIVersion` is above every version this client was
  /// tested against.
  belowServerMinimum,

  /// The engine reported no API version this client can read.
  apiVersionUnknown,

  /// The link failed while the ladder ran.
  linkError,

  /// The endpoint choice names a socket path [dockerSocketPathProblem]
  /// refuses, so the ladder did not run.
  invalidChoice,

  /// The server's `docker` program is a path [dockerProgramPathProblem]
  /// refuses, so the ladder did not run (CN-16).
  invalidProgram,
}

/// The route a [DockerEndpointState] names (03 §5.4, §5.9; SAF-08).
@immutable
final class DockerEndpointRoute {
  const DockerEndpointRoute({
    required this.rank,
    required this.socketPath,
    required this.runtime,
    required this.rootEquivalence,
    this.mode,
    this.peerCredentialsExposedBy,
    this.dockerProgram = 'docker',
  });

  final DockerRank rank;
  final String socketPath;

  /// The Dropbear release a socket forward runs through when it is one
  /// where the engine sees forwarded connections as root (CN-15,
  /// CVE-2025-14282); null on other servers and on relays.
  final DropbearRelease? peerCredentialsExposedBy;

  /// The program compose commands run for `docker` on this server: its
  /// [SetDockerProgram] path, or `docker` on the exec `PATH` (CN-16).
  final String dockerProgram;

  /// The engine as its API names it: Podman when `_ping` carries
  /// `Libpod-API-Version` or `/version` names a Podman component, even
  /// behind a Docker path (M13), otherwise Docker.
  final EngineRuntime runtime;

  /// Rootful or rootless by the path; null for a custom path.
  final EngineMode? mode;

  final DockerRootEquivalence rootEquivalence;
}

/// Which engine socket a server's Docker endpoint uses (CN-09, D54).
@immutable
sealed class DockerEndpointChoice {
  const DockerEndpointChoice();
}

/// The engine finds the socket itself (03 §5.4's discovery).
final class DockerEndpointAuto extends DockerEndpointChoice {
  const DockerEndpointAuto();

  @override
  bool operator ==(Object other) => other is DockerEndpointAuto;

  @override
  int get hashCode => (DockerEndpointAuto).hashCode;
}

/// A socket the user named, tried first.
sealed class DockerEndpointSocket extends DockerEndpointChoice {
  const DockerEndpointSocket(this.socketPath);

  /// The socket's absolute path on the server.
  final String socketPath;
}

/// One of the sockets the probe found (03 §5.4).
final class DockerEndpointDetected extends DockerEndpointSocket {
  const DockerEndpointDetected(super.socketPath);

  @override
  bool operator ==(Object other) =>
      other is DockerEndpointDetected && other.socketPath == socketPath;

  @override
  int get hashCode => Object.hash(DockerEndpointDetected, socketPath);
}

/// A path the user typed, such as a socket outside 03 §5.4's list.
final class DockerEndpointCustom extends DockerEndpointSocket {
  const DockerEndpointCustom(super.socketPath);

  @override
  bool operator ==(Object other) =>
      other is DockerEndpointCustom && other.socketPath == socketPath;

  @override
  int get hashCode => Object.hash(DockerEndpointCustom, socketPath);
}

/// One inspected container as it crosses (03 §7.12 CTR-03, CTR-04): the
/// inspect fields the panels use, with the command line and the health
/// checks' output masked by the engine (03 §8.9), so a secret reaches the
/// app only behind [MaskedValue]. Env and label values are masked by key.
@immutable
final class ContainerDetails {
  const ContainerDetails({
    required this.id,
    this.name,
    this.created,
    this.image,
    this.platform,
    this.restartCount,
    this.path,
    this.args = const [],
    this.state,
    this.config,
    this.hostConfig,
    this.mounts = const [],
    this.networkSettings,
  });

  final String id;
  final String? name;
  final DateTime? created;

  /// The image id; [ContainerDetailsConfig.image] names what it was
  /// created from.
  final String? image;
  final String? platform;
  final int? restartCount;

  /// The program the container runs (`Path`), as it is: 03 §8.9 never
  /// reads a program as an option.
  final String? path;

  /// `Args`, masked as the command line after [path].
  final List<MaskedValue> args;

  final ContainerDetailsState? state;
  final ContainerDetailsConfig? config;
  final ContainerHostConfig? hostConfig;
  final List<ContainerMount> mounts;
  final ContainerNetworkSettings? networkSettings;
}

/// An inspected container's `State` (CTR-03, CTR-04).
@immutable
final class ContainerDetailsState {
  const ContainerDetailsState({
    this.status,
    this.running = false,
    this.paused = false,
    this.restarting = false,
    this.oomKilled = false,
    this.dead = false,
    this.pid,
    this.exitCode,
    this.error,
    this.startedAt,
    this.finishedAt,
    this.health,
  });

  final String? status;
  final bool running;
  final bool paused;
  final bool restarting;
  final bool oomKilled;
  final bool dead;
  final int? pid;
  final int? exitCode;
  final String? error;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final ContainerDetailsHealth? health;
}

/// `State.Health` (CTR-04).
@immutable
final class ContainerDetailsHealth {
  const ContainerDetailsHealth({
    this.status = HealthStatus.none,
    this.failingStreak,
    this.log = const [],
  });

  final HealthStatus status;
  final int? failingStreak;
  final List<ContainerHealthCheck> log;
}

/// One health check's result (`State.Health.Log[]`), its output masked
/// (03 §8.9): a check command can print what it was given.
@immutable
final class ContainerHealthCheck {
  const ContainerHealthCheck({
    this.start,
    this.end,
    this.exitCode,
    this.output,
  });

  final DateTime? start;
  final DateTime? end;
  final int? exitCode;
  final MaskedValue? output;
}

/// The inspect `Config` fields the panels use, with `Entrypoint` and
/// `Cmd` masked as one command line (03 §8.9).
@immutable
final class ContainerDetailsConfig {
  const ContainerDetailsConfig({
    this.hostname,
    this.image,
    this.user,
    this.workingDir,
    this.stopSignal,
    this.tty = false,
    this.env = const [],
    this.entrypoint = const [],
    this.cmd = const [],
    this.labels = const {},
  });

  final String? hostname;
  final String? image;
  final String? user;
  final String? workingDir;
  final String? stopSignal;

  /// `Tty`, which decides the log framing (03 §5.6).
  final bool tty;
  final List<EnvVar> env;
  final List<MaskedValue> entrypoint;
  final List<MaskedValue> cmd;
  final Map<String, MaskedValue> labels;
}
