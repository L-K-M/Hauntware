import 'protocol.dart';

/// The id [request] carries for its own answer, or null when it names
/// none: what [RequestRejected.requestId] echoes, so the app settles the
/// one read, open or run the engine refused instead of waiting on an
/// answer that will not come. Every request type is classified, so a new
/// one must say whether it carries an id.
String? requestIdOf(EngineRequest request) => switch (request) {
  EnrollSync(:final requestId) ||
  RunSyncRound(:final requestId) ||
  SignOutSync(:final requestId) => requestId,
  UnitQuery(:final requestId) ||
  JobHistoryQuery(:final requestId) ||
  ReadEditable(:final requestId) ||
  RedactLines(:final requestId) ||
  CheckTlsEndpoints(:final requestId) ||
  NewRecoveryCode(:final requestId) ||
  SetRecoveryCode(:final requestId) ||
  RecoveryStatusRequest(:final requestId) ||
  ExportVault(:final requestId) ||
  RestoreVault(:final requestId) ||
  ReadServerDraft(:final requestId) ||
  SaveServer(:final requestId) ||
  TestServerConnection(:final requestId) ||
  DuplicateServer(:final requestId) ||
  DeleteServer(:final requestId) ||
  SetServerPrefs(:final requestId) ||
  PutRule(:final requestId) ||
  RemoveRule(:final requestId) ||
  ReadUserCrontabs(:final requestId) ||
  ReadDiskUsage(:final requestId) ||
  ReadTimerDetail(:final requestId) ||
  ReadSmart(:final requestId) ||
  ReadPackages(:final requestId) ||
  ReadRestarts(:final requestId) ||
  ReadFirewall(:final requestId) ||
  ReadSshdPosture(:final requestId) ||
  ReadAccounts(:final requestId) ||
  ReadHistory(:final requestId) => requestId,
  DockerQuery(:final queryId) || HostQuery(:final queryId) => queryId,
  OpenLogStream(:final streamId) || CloseStream(:final streamId) => streamId,
  DockerWatch(:final watchId) || DockerUnwatch(:final watchId) => watchId,
  OpenPortForward(:final forwardId) ||
  ClosePortForward(:final forwardId) => forwardId,
  OpenTerminal(:final terminalId) ||
  TerminalInput(:final terminalId) ||
  TerminalResize(:final terminalId) ||
  TerminalEndInput(:final terminalId) ||
  CloseTerminal(:final terminalId) => terminalId,
  RunAction(:final planId) || CancelAction(:final planId) => planId,
  AcknowledgeOperation(:final id) => id,
  AnswerPrompt(:final promptId) => promptId,
  // The requests that carry no answer correlation: each is answered by a
  // fixed event, or its outcome reaches the app another way.
  Hello() ||
  Shutdown() ||
  ReadPinConflicts() ||
  ResolvePinConflict() ||
  ImportSshConfig() ||
  ConfirmEndpoints() ||
  SetMonitorSet() ||
  Connect() ||
  Disconnect() ||
  SetAppActivity() ||
  Subscribe() ||
  Unsubscribe() ||
  RefreshSubscription() ||
  SetCadenceProfile() ||
  SetServerCadenceCap() ||
  FootprintQuery() ||
  SetDockerEndpoint() ||
  SetDockerProgram() ||
  PlanAction() ||
  SetSafetyPolicy() ||
  SetSyncSecrets() ||
  SetDeviceName() ||
  SetPinPublication() ||
  SetAdminMode() ||
  AuditQuery() ||
  AnswerKeystore() ||
  HandleAlert() => null,
};
