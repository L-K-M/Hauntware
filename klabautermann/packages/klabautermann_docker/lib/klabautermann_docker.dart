/// Pure-Dart Docker Engine API client for Klabautermann (03 §3.3, §5.4
/// to §5.9): an HTTP/1.1 client over an injected [ByteDuplex], the
/// stdcopy demultiplexer and log line handling, API version negotiation
/// with feature gates, and the thin versioned [DockerClient]. No SSH
/// types, no Flutter, no `dart:io`: `klabautermann_core` adapts
/// `seance_core`'s `ByteDuplex` to the seam defined here.
library;

export 'src/api_version.dart'
    show
        ApiFeatureGates,
        ApiVersion,
        DockerNegotiation,
        DockerServerVersion,
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
export 'src/docker_client.dart' show DockerClient, negotiateDockerClient;
export 'src/duplex.dart' show ByteDuplex, DuplexOpener, HijackedDuplex;
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
export 'src/http_client.dart'
    show DockerHttpClient, defaultMaxBufferedBytes, defaultMaxConnections;
export 'src/http_types.dart'
    show DockerCancelToken, DockerHttpRequest, DockerResponse, HttpHeaders;
export 'src/json_streams.dart' show byteStreamToJsonValues, byteStreamToLines;
export 'src/docker_parse_result.dart' show DockerParseResult;
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
