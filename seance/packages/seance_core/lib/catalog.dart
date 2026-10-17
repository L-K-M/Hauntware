/// The shared sync catalog (decision D6; docs/design/catalog-library.md):
/// the record coordinator with its handler seam and write path, the
/// persistent record store, the server-config store and its sync tuples,
/// enrollment, the host-key and pin-verdict seams, the file-backed
/// host-key and vault stores, endpoint pins and their file store, record
/// crypto, the read-only server catalog, and the file primitives behind
/// the stores' default writer. A secondary library of `seance_core`:
/// import it beside
/// `package:seance_core/seance_core.dart`.
///
/// Poltergeist drives the coordinator with its `bookmark:` handler; its
/// `poltergeist_core` barrel re-exports these types, so Poltergeist code
/// keeps importing them from there.
library;

export 'src/catalog/catalog_snapshot.dart' show CatalogSnapshot;
export 'src/catalog/catalog_writer.dart' show CatalogWriter, WriteOutcome;
export 'src/catalog/endpoint_pin_store.dart' show EndpointPin, EndpointPinStore;
export 'src/catalog/enrollment.dart'
    show
        EnrollmentResult,
        KdfDowngradeException,
        RegistrationClosedException,
        SyncAccount,
        SyncAccountMode,
        SyncCredentialStore,
        SyncEnrollment,
        SyncEnrollmentApi,
        SyncEnrollmentException,
        SyncEnrollmentState,
        syncNoticeAccountAuthFailed,
        syncNoticePassphraseCheckFailed,
        syncPassphraseCheckFailedMessage,
        syncRegistrationClosedMessage;
export 'src/catalog/host_key_mutations.dart'
    show
        ConflictAwareHostKeyStore,
        HostKeyInstallResult,
        HostKeyMutationGate,
        InMemoryConflictAwareHostKeyStore;
export 'src/catalog/persistent_record_store.dart'
    show
        PersistentLocalRecordStore,
        SyncCursorRejectedException,
        SyncRecordStore,
        recordStoreQuarantinePath;
export 'src/catalog/pin_verdicts.dart'
    show
        InMemoryPinVerdictStore,
        InMemorySyncTripwireStore,
        PinVerdictStore,
        SyncTripwireStore;
export 'src/catalog/push_policy.dart' show PushPolicy;
export 'src/catalog/record_coordinator.dart'
    show
        ApplyReport,
        CatalogMode,
        HostKeyConflict,
        RecordCoordinator,
        SyncRoundResult,
        isDecryptableSyncId;
export 'src/catalog/record_crypto.dart' show RecordCrypto;
export 'src/catalog/record_handler.dart'
    show
        ApplyContext,
        ApplyOutcome,
        ApplyPhase,
        RecordHandler,
        outranksMaterialized;
export 'src/catalog/server_config_store.dart'
    show
        FileServerConfigStore,
        ServerSyncTuple,
        SyncTrackingServerStore,
        serverStoreQuarantinePath;
export 'src/catalog/sync_tuple.dart' show SyncTuple;
// F3b's file-backed host-key and vault stores
// (docs/design/catalog-library.md section 8). Exported here rather than
// from seance_core.dart, where these names would clash with the Séance
// app's own stores until the app switches.
export 'src/store/file_host_key_store.dart' show FileHostKeyStore;
export 'src/store/file_vault_store.dart'
    show FileVaultStore, VaultRekeyJournal, VaultRekeyOutcome;
// The endpoint pins' file store (D16, 03-ARCHITECTURE.md 4.7), beside
// the host-key store whose conventions it shares.
export 'src/store/file_endpoint_pin_store.dart'
    show
        EndpointPinsNewerVersionException,
        FileEndpointPinStore,
        endpointPinsFileName;
// The file primitives behind the stores' default writer, which
// Poltergeist's local-file safety and transfer journal share.
export 'src/store/file_permissions.dart' show restrictLocalPathPermissions;
export 'src/store/local_directory_sync.dart' show syncLocalDirectory;
