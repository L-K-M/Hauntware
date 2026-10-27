/// Klabautermann's pure-Dart engine layer: the D18 engine isolate, its
/// plain-data protocol and the client the app composes over, the device
/// settings store, the instance lock and the log viewer's line model
/// (docs/design/klabautermann/03, sections 3.2, 4.10, 10.1 and 10.8).
library;

// Pull-only sync (D14, D63): the policy the engine's coordinator runs
// under, which the app's pull-only test checks, and the keystore entry
// names the app binds ghost_keystore with (03 §4.5, D62).
export 'src/alerts/alert_evaluator.dart' show AlertMetric;
export 'src/alerts/alert_rules.dart';
export 'src/catalog/klabautermann_records.dart' show SyncedRule;
export 'src/history/history_store.dart'
    show
        HistoryBucket,
        HistoryGap,
        HistoryProvenance,
        HistoryRange,
        HistoryStat,
        HistoryTier;
export 'src/catalog/engine_sync.dart' show engineSyncPushPolicy;
export 'src/catalog/sync_credentials.dart'
    show klabautermannApiKeyPrefix, klabautermannMasterKeyEntry;
// The System tab's Certificates section (CRT-01): the endpoints the
// device checks and what each check found.
export 'src/certificates/tls_check.dart'
    show
        TlsCertificateFacts,
        TlsCheckFailure,
        TlsEndpoint,
        TlsEndpointCheck,
        kTlsDefaultPort,
        kTlsEndpointsMax;
export 'src/engine/engine_client.dart';
// What a substitute engine for IsolateEngineClient.spawn's entryPoint is
// handed; the app's restart test runs one.
export 'src/engine/engine_isolate.dart' show EngineStart;
export 'src/engine/protocol.dart';
// The plain-data plan parts an ActionPreview carries (03 §8.5), and
// DangerLinter's findings in it. The linter itself checks what is pasted
// into a container shell, as in Séance's shells (03 §7.13).
export 'src/operations/plan_types.dart';

export 'package:seance_core/seance_core.dart'
    show DangerFinding, DangerLinter, DangerSeverity;
// The signal, unit verb and power verb an ActionIntent names (PRC-02,
// SVC-03, SYS-03).
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        KillSignal,
        PowerVerb,
        SystemctlVerb,
        OnCalendarElapse,
        OnCalendarResult,
        TimerDetail;

// FL-21's monitor set rules, which the engine enforces and the app's
// toggles offer (03 §4.3 step 4).
export 'src/fleet/monitor_set.dart'
    show MonitorEligibility, kMonitorSetLimit, monitorEligibilityOf;
// The log viewer's line store and SGR reader (03 §10.8).
export 'src/logs/line_reading.dart';
export 'src/logs/log_buffer.dart';
export 'src/logs/sgr.dart';
// The app's settings.json (03 §4.10), and the atomic writer the app's
// other device-local files (window_state.json) share with it.
export 'src/settings/device_settings_store.dart'
    show
        DeviceSettingsIssue,
        DeviceSettingsIssueKind,
        DeviceSettingsReadOnlyException,
        DeviceSettingsStore,
        DeviceSettingsWriter,
        DockerEndpointOverride,
        deviceSettingsFileName,
        deviceSettingsSchemaVersion,
        writeFileAtomically;
// One desktop instance per support directory (03 §4.10); the error-code
// rule stays internal.
export 'src/settings/instance_lock.dart'
    show
        InstanceLock,
        InstanceLockAcquired,
        InstanceLockAttempt,
        InstanceLockHeld,
        InstanceLockUnavailable,
        SupportDirectoryAccess,
        instanceLockFileName;

// 03 §3.2: the app reaches seance_core, klabautermann_host and
// klabautermann_docker types only through this barrel, each behind an
// explicit `show` list that changes as a milestone wires types in or
// retires them.
// The host types are the plain data that sampling results and
// HostProfileChanged carry (D52), the file names
// HostProfile.showsHostFigures takes (D50), and the log viewer's journal
// rows.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        AccountsSnapshot,
        CpuPercentages,
        CronSnapshot,
        DiskUsageEntry,
        DiskUsageListing,
        DiskRate,
        FsMount,
        FsSnapshot,
        GpuDevice,
        GpuSnapshot,
        GpuSource,
        HostAccount,
        HostProfile,
        HostSession,
        JournalEntry,
        LoadAvg,
        NetRate,
        ProcsSelection,
        RootEquivalence,
        SmartDisk,
        SmartVerdict,
        SystemWideProcFile,
        SystemdUnit,
        TempSensor,
        TempsSnapshot,
        TimersSnapshot,
        UnitListFormat,
        UnitsSnapshot;
// The System tab's Updates section (PKG-01 to PKG-04): what a
// PackagesReport's or a RestartReport's check found.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        KernelState,
        PackageCheck,
        PackageCheckFailure,
        PackageManager,
        PackageUpdate,
        RebootState,
        RestartCheck,
        RestartTool,
        kPackageUpdatesKept;
// The System tab's Firewall section (NET-06): what a FirewallReport
// read.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        FirewallChain,
        FirewallRead,
        FirewalldStatus,
        FirewalldZone,
        UfwRule,
        UfwStatus;

// The System tab's SSH server section (SEC-01): what an
// SshdPostureReport read.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        SshdForwarding,
        SshdForwardingBlock,
        SshdMatchContext,
        SshdPosture,
        SshdRootLogin;

// A process's details and owner (PRC-04, PRC-05), as a HostResult's
// ProcessDetails carry them.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        ContainerRuntime,
        ProcessAttribution,
        ProcessDetail,
        ProcessLimit,
        kProcessEnvironLimit;
// The Logs panel's boot picker and /var/log browser (LOG-08, LOG-09): a
// HostResult's rows and the boot a source reads.
export 'package:klabautermann_host/klabautermann_host.dart'
    show JournalBoot, JournalBootEntry, LogCompression, LogFileEntry;
// The System tab's listening ports (NET-04): the sockets a HostResult
// carries.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        ListeningPortsRead,
        ListeningSocket,
        PortProcess,
        PortProtocol,
        PortsTool;
// The System tab's out-of-memory kills (MEM-03): the read a HostResult
// carries.
export 'package:klabautermann_host/klabautermann_host.dart'
    show OomKill, OomKillsRead, OomLogSource;
// The System tab's boots section (BOOT-02, BOOT-03): how earlier boots
// ended and the kernels a HostResult carries.
export 'package:klabautermann_host/klabautermann_host.dart'
    show BootEnd, KernelCheck, KernelCheckState, kBootEndsRead;
// The System tab's processor section (CPU-07): the model and topology a
// HostResult carries.
export 'package:klabautermann_host/klabautermann_host.dart' show CpuTopology;
// The System tab's interfaces section (NET-02, NET-03): the interfaces
// and socket counts a HostResult carries.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        InterfacesRead,
        NetAddress,
        NetAddressFamily,
        NetInterface,
        NetLinkState,
        SocketCounts,
        TcpState;
// The Disks section's mount details and the Swap section (DSK-05,
// DSK-14): the mounts and swap devices a HostResult carries.
export 'package:klabautermann_host/klabautermann_host.dart'
    show MountEntry, MountsRead, SwapDevice, SwapKind;
// The Jobs panel (JOB-01, JOB-02): the jobs rows a CronResult carries, the
// timer rows the app builds from a TimersResult, their schedule
// descriptions and their runs as plain CronRun values (D52), and the
// engine's limits and names its words follow.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        CalendarSchedule,
        CronDayMatch,
        CronDst,
        CronFieldItem,
        CronFields,
        CronJob,
        CronJobEntry,
        CronMacro,
        CronRun,
        CronSchedule,
        JobEntry,
        JobRunsUnknown,
        MonotonicSchedule,
        PeriodicJobEntry,
        ScheduleDescription,
        SystemdTimer,
        TimerJobEntry,
        kCalendarIterationsSystemd,
        kCronHorizonDays,
        kOwnCrontabSource,
        userCrontabSource;

export 'src/sampling/sample_results.dart' show kCronLinesEvaluated;
// Pause and Resume rewrite a cron line through the edit pipeline
// (JOB-07): the crontab that holds it and the text with it toggled.
export 'src/jobs/cron_pause.dart' show cronPauseTarget, togglePausedCronJob;

// Detached operations (03 §7.17): which directory an operation records
// in, and how far each directory's listing got.
export 'package:klabautermann_host/klabautermann_host.dart'
    show OpDirectoryKind, OpDirectoryListing, OpDirectoryState;
// Job history (JOB-04, JOB-05): what a JobHistoryResult carries.
export 'package:klabautermann_host/klabautermann_host.dart'
    show AnacronJob, AnacronPeriod, LoggedCronRun, TimerLastRun;
// The v1 unit reads (SVC-08, SVC-10): the resources and sockets a
// UnitQueryResult carries.
export 'package:klabautermann_host/klabautermann_host.dart'
    show UnitResources, UnitSocket;
// The footprint view (SAF-14, 03 §8.11): the manifest rows and backup
// index entries a FootprintState carries.
export 'package:klabautermann_host/klabautermann_host.dart'
    show BackupEntry, FootprintKind, FootprintRow;
// The Logs panel's LOG-04 notice: the access check's journal row (K04)
// over the probe's HostProfile.
export 'package:klabautermann_host/klabautermann_host.dart'
    show AccessReport, evaluateAccess;
// The app resolves `~/.ssh/config` for the FL-02 import with Séance's home
// rule, which also undoes a macOS sandbox's container `HOME`.
export 'package:seance_core/seance_core.dart' show expandHomePath;
// The Access tab and panel gating (CN-24, CN-09, SAF-08; 03 §10.4, D51):
// the access check's rows and the panels' capability rules over the
// probe's HostProfile, and the quoting of the fix commands the tab copies
// and never runs.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        AccessFix,
        AccessItem,
        AccessReason,
        AccessRow,
        AccessStatus,
        Capability,
        EngineEndpoint,
        EngineMode,
        EngineRuntime,
        FixElevation,
        HostPanel,
        evaluatePanel;
export 'package:seance_core/seance_core.dart' show quoteShellWord;
// Hand-offs to Séance and Poltergeist (X-03, X-04, X-10; D12): the suite's
// link builders, which refuse anything but a server and a folder, so no
// link can carry a command (X8).
export 'package:seance_core/seance_core.dart'
    show
        buildPoltergeistBrowse,
        buildSeanceConnect,
        poltergeistBrowseRoute,
        poltergeistDeepLinkScheme,
        seanceConnectRoute,
        seanceDeepLinkScheme;

// A one-off command's words, split as a shell would without expanding
// them (CTX-08).
export 'src/operations/command_words.dart' show splitCommandWords;

// The sync sign-in form (03 §4.3 step 1) checks its fields with the
// suite's enrollment rule before the engine is asked, and the pull-only
// test names the push policy.
export 'package:seance_core/catalog.dart' show PushPolicy;
export 'package:seance_core/seance_core.dart'
    show SyncEnrollmentIssue, SyncEnrollmentMode, validateSyncEnrollment;
// The login password prompt (03 §4.5) hands ghost_servers' credential
// dialog the auth method it asks for.
export 'package:seance_core/seance_core.dart' show AuthMethod;
// The id a server added in the editor is saved under (FL-03), minted as
// the catalog mints every record id.
export 'package:seance_core/seance_core.dart' show uuidV4;
// Séance's synced snippets (03 §7.21, AUT-01), which SnippetsChanged
// carries and the Snippets view fills and runs.
export 'package:seance_core/seance_core.dart' show Snippet;
// A process row's masked arguments (03 §8.9): the Processes panel shows
// their display and reveals one on request.
export 'package:klabautermann_docker/klabautermann_docker.dart'
    show MaskedValue;

// The Docker tab (03 §7.12 to §7.14, §10.1): the route a
// DockerEndpointState names, the plain-data Docker models a
// DockerResult or DockerListChanged carries (D52), and the Overview's
// Docker summary over them (OV-05).
export 'src/docker/docker_ladder.dart'
    show
        DockerNoRouteReason,
        DockerRank,
        DockerRootEquivalence,
        DockerRouteLabel;
// CN-09's endpoint choice (D54) and CN-16's docker program: the checks a
// typed or stored path gets before it is kept or sent, and the Access
// tab's Docker facts (CN-24) from a server's DockerEndpointState.
export 'src/docker/docker_ladder.dart'
    show
        DockerSocketPathProblem,
        dockerProgramPathProblem,
        dockerSocketPathProblem;
export 'src/docker/docker_access.dart' show dockerAccessFacts;
// CN-15: the Dropbear release a socket forward runs through, when it
// exposes forwarded connections' peer credentials.
export 'src/docker/dropbear.dart' show DropbearRelease;
// When an update check reads a registry again (IMG-05, D68).
export 'src/docker/image_updates.dart'
    show kImageUpdateBackoff, kImageUpdateFresh;

export 'package:klabautermann_host/klabautermann_host.dart'
    show ComposeFacts, DockerAccessFacts;

export 'package:klabautermann_docker/klabautermann_docker.dart'
    show
        ApiVersion,
        ComposeGrouping,
        ComposeProject,
        ComposeService,
        ContainerHostConfig,
        ContainerMount,
        ContainerNetwork,
        ContainerNetworkSettings,
        ContainerPort,
        ContainerRestartPolicy,
        ContainerSummary,
        DiskUsageTotals,
        DockerServerVersion,
        DockerSummary,
        EngineComponent,
        EngineInfo,
        EnvVar,
        ExternalManager,
        HealthStatus,
        ImageDigestComparison,
        ImageSummary,
        ImageUpdateIssue,
        ImageUpdateStatus,
        LogConfig,
        NetworkIpamConfig,
        NetworkSummary,
        Ownership,
        OwnershipMarker,
        RegistryRateLimit,
        SystemDf,
        VolumeSummary,
        dockerSummary,
        kComposeMaxScale;
// A container's managed-by badge (DKE-10), from its inspected labels; a
// stack's is its ComposeProject.ownership.
export 'package:klabautermann_docker/klabautermann_docker.dart'
    show detectOwnership;
// A container's label links (CTR-11): the pages its labels point at.
export 'package:klabautermann_docker/klabautermann_docker.dart'
    show LabelLink, LabelLinkSource, labelLinks;
// The coverage card's external-monitor finding (03 §9.5 item 3): K04's
// rule over a `units` reading, and what it reports.
export 'package:klabautermann_host/klabautermann_host.dart'
    show ExternalMonitorReport, ExternalMonitorUnit;

export 'src/sampling/sample_results.dart' show externalMonitorsIn;

// The Overview's threshold-band announcements (A11Y-15, D60): the rule
// model's hysteresis evaluator, whose `for` durations debounce a band.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        RuleEvalScope,
        RulePhase,
        RuleScope,
        ThresholdBound,
        ThresholdOp,
        ThresholdRule,
        ThresholdState,
        evaluateThreshold;
