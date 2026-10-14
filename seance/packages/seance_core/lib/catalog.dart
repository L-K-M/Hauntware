/// The shared sync catalog (decision D6; docs/design/catalog-library.md):
/// the persistent record store, the server-config store and its sync
/// tuples, enrollment, the host-key and pin-verdict seams, record crypto,
/// the materialized server catalog, and the file primitives behind the
/// stores' default writer. A secondary library of `seance_core`: import it
/// beside `package:seance_core/seance_core.dart`.
///
/// Poltergeist's coordinator drives these types today; its
/// `poltergeist_core` barrel re-exports them, so Poltergeist code keeps
/// importing them from there.
library;

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
export 'src/catalog/record_crypto.dart' show RecordCrypto, isDecryptableSyncId;
export 'src/catalog/seance_server_catalog.dart' show SeanceServerCatalog;
export 'src/catalog/server_config_store.dart'
    show
        FileServerConfigStore,
        ServerSyncTuple,
        SyncTrackingServerStore,
        // Poltergeist's coordinator stamps its server tombstone records
        // with the store's rule, so the two never disagree.
        deletionStamp,
        serverStoreQuarantinePath;
export 'src/catalog/sync_tuple.dart' show SyncTuple;
// The file primitives behind the stores' default writer, which
// Poltergeist's local-file safety and transfer journal share.
export 'src/store/file_permissions.dart' show restrictLocalPathPermissions;
export 'src/store/local_directory_sync.dart' show syncLocalDirectory;
