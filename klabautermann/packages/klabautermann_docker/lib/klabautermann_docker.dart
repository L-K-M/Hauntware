/// Pure-Dart Docker Engine API client for Klabautermann (03 §3.3, §5.4
/// to §5.9, §7.12 to §7.16): an HTTP/1.1 client over an injected
/// [ByteDuplex], the stdcopy demultiplexer and log line handling, API
/// version negotiation with feature gates, the thin versioned
/// [DockerClient], tolerant typed models, secret masking, compose
/// discovery and command builders, and the pure event-refresh and image
/// digest logic. No SSH types, no Flutter, no `dart:io`:
/// `klabautermann_core` adapts `seance_core`'s `ByteDuplex` to the seam
/// defined here.
library;

export 'src/api_version.dart'
    show
        ApiFeatureGates,
        ApiVersion,
        DockerNegotiation,
        DockerServerVersion,
        EngineComponent,
        PingInfo,
        SystemDfShape,
        apiVersionAttestations,
        apiVersionEventV2,
        apiVersionImageContainers,
        apiVersionLogsContentType,
        apiVersionSystemDf152,
        apiVersionSystemDf153,
        clientApiFloor,
        clientMaxTestedApiVersion,
        negotiateApiVersion,
        parsePingHeaders,
        parseServerVersion;
export 'src/compose/commands.dart'
    show
        ComposeInvocation,
        composeConfig,
        composeDown,
        composeNamePattern,
        composePs,
        composePull,
        composeRestart,
        composeUp,
        composeVersion,
        validateAbsolutePath,
        validateComposeProjectName,
        validateComposeServiceName,
        validateSocketPath;
export 'src/compose/grouping.dart'
    show ComposeGrouping, ComposeProject, ComposeService, groupComposeProjects;
export 'src/compose/labels.dart' show ComposeLabelKeys, ComposeLabels;
export 'src/compose/ownership.dart'
    show ExternalManager, Ownership, OwnershipMarker, detectOwnership;
export 'src/compose/parsers.dart'
    show
        ComposeConfig,
        ComposePsEntry,
        ComposePublisher,
        ComposeServiceConfig,
        ComposeVersionInfo,
        parseComposeConfig,
        parseComposePsEntries,
        parseComposePsJson,
        parseComposeServiceHashes,
        parseComposeVersion;
export 'src/docker_client.dart' show DockerClient, negotiateDockerClient;
export 'src/docker_parse_result.dart' show DockerParseResult;
export 'src/duplex.dart' show ByteDuplex, DuplexOpener, HijackedDuplex;
export 'src/endpoints.dart' show DockerEndpoints, DockerSignal;
export 'src/errors.dart'
    show
        DockerApiException,
        DockerBadRequestException,
        DockerBodyTooLargeException,
        DockerCancelledException,
        DockerConflictException,
        DockerException,
        DockerNotFoundException,
        DockerProtocolException,
        DockerServerException,
        DockerTimeoutException,
        DockerTransportException,
        DockerUnexpectedStatusException,
        DockerVersionException,
        NegotiationRefusal,
        NegotiationRefusedException;
export 'src/events_refresh.dart'
    show
        DockerList,
        EventRefreshPlan,
        eventGapThreshold,
        listsForEvent,
        planEventRefresh;
export 'src/http_client.dart'
    show DockerHttpClient, defaultMaxBufferedBytes, defaultMaxConnections;
export 'src/http_types.dart'
    show DockerCancelToken, DockerHttpRequest, DockerResponse, HttpHeaders;
export 'src/image_digest.dart'
    show
        ImageDigestComparison,
        ImageUpdateStatus,
        RegistryManifestHead,
        RepoDigest,
        compareImageDigest,
        parseRegistryHead;
export 'src/json_streams.dart' show byteStreamToJsonValues, byteStreamToLines;
export 'src/log_resume.dart'
    show
        TimestampedLogLine,
        dropInclusiveSince,
        dropInclusiveSinceLines,
        joinTimestampedLogLines,
        lastDeliveredTimestamp,
        parseTimestampedLogLine,
        parseTimestampedLogLines;
export 'src/log_time.dart' show LogTimestamp;
export 'src/masking.dart'
    show
        MaskedValue,
        isSecretKey,
        maskUrlCredentials,
        maskedEnvEntry,
        maskedLabels,
        maskedValueFor,
        maskedValueWithUrlCheck,
        secretKeyPattern;
export 'src/models/container.dart'
    show
        ContainerConfig,
        ContainerHealth,
        ContainerHostConfig,
        ContainerInspect,
        ContainerMount,
        ContainerNetwork,
        ContainerNetworkSettings,
        ContainerPort,
        ContainerRestartPolicy,
        ContainerState,
        ContainerSummary,
        EnvVar,
        HealthLog,
        HealthStatus,
        LogConfig,
        healthFromStatus,
        parseContainerInspect,
        parseContainerSummaries,
        parseEnv,
        swarmServiceNameHint;
export 'src/models/engine_info.dart' show EngineInfo, parseEngineInfo;
export 'src/models/events.dart' show DockerEvent, parseDockerEvent;
export 'src/models/image.dart'
    show
        ImageConfig,
        ImageInspect,
        ImageSummary,
        parseImageInspect,
        parseImageSummaries;
export 'src/models/network.dart'
    show
        NetworkContainer,
        NetworkIpamConfig,
        NetworkSummary,
        builtinNetworkNames,
        parseNetworkSummaries;
export 'src/models/pull.dart'
    show ProgressDetail, PullProgress, parsePullProgress;
export 'src/models/stats.dart'
    show
        BlockIoStats,
        ContainerStats,
        CpuStats,
        MemoryStats,
        NetworkStats,
        StatsDelta,
        computeStatsDelta,
        cpuPercentDelta,
        effectiveMemoryUsage,
        parseContainerStats;
export 'src/models/volume.dart' show VolumeSummary, parseVolumeSummaries;
export 'src/stdcopy.dart'
    show
        BoundedLogRing,
        LogFraming,
        LogFramingChoice,
        LogLine,
        StdcopyFrame,
        StdcopyKind,
        contentTypeMultiplexed,
        contentTypeRawStream,
        defaultLogRingChars,
        defaultLogRingLines,
        defaultMaxLogLineChars,
        defaultMaxStdcopyFrameBytes,
        demuxStdcopy,
        rawLogFrames,
        resolveLogFraming,
        splitLogLines;
