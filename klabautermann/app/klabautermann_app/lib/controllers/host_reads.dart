import 'package:klabautermann_core/klabautermann_core.dart';

import 'engine_reads.dart';

/// The one-shot host reads the monitoring surfaces ask for: host queries
/// (LOG-08, LOG-09), unit reads (SVC-07 to SVC-10), export redaction
/// (LOG-10) and certificate checks (CRT-01). One concern of its own for
/// one engine run; a stopped engine answers each read's no-link value.
final class HostReads {
  HostReads(this._engine, this._onEngineStopped) {
    _hostQueries = _reads(
      (event) => switch (event) {
        HostResult(:final queryId) => (queryId, event),
        _ => null,
      },
    );
    _unitQueries = _reads(
      (event) => switch (event) {
        UnitQueryResult(:final requestId) => (requestId, event),
        _ => null,
      },
    );
    _redactions = _reads(
      (event) => switch (event) {
        RedactedLines(:final requestId, :final text) => (requestId, text),
        _ => null,
      },
    );
    _tlsChecks = _reads(
      (event) => switch (event) {
        TlsEndpointsChecked(:final requestId, :final checks) => (
          requestId,
          checks,
        ),
        _ => null,
      },
    );
  }

  final EngineClient _engine;
  final void Function() _onEngineStopped;

  /// The host queries waiting for their answers; a stopped engine answers
  /// no link.
  late final EngineReads<HostResult> _hostQueries;
  int _nextHostQuery = 0;

  /// Unit reads waiting on the engine, likewise.
  late final EngineReads<UnitQueryResult> _unitQueries;
  int _nextUnitQuery = 0;

  /// The [redactLines] requests waiting for the engine, likewise: null
  /// when the engine has stopped.
  late final EngineReads<String?> _redactions;
  int _nextRedaction = 0;

  late final EngineReads<List<TlsEndpointCheck>?> _tlsChecks;
  var _nextTlsCheck = 0;

  /// One [EngineReads] per read concern: the monitoring controller's sends
  /// treat a refused port as a stopped engine for everything, so each read
  /// does too and reports it through the same callback.
  EngineReads<A> _reads<A>((String, A)? Function(EngineEvent) answerOf) =>
      EngineReads(
        _engine,
        answerOf,
        sendFailure: SendFailure.engineStopped,
        onEngineStopped: _onEngineStopped,
      );

  /// Reads [query] on [serverId]: the files under `/var/log` or the
  /// journal's boots (LOG-08, LOG-09). A stopped engine answers no link.
  Future<HostResult> queryHost(String serverId, HostQuerySpec query) {
    final queryId = 'host-${_nextHostQuery++}';
    return _hostQueries.read(
      queryId,
      HostQuery(serverId: serverId, queryId: queryId, query: query),
      () => _noHostLink(serverId, queryId),
    );
  }

  /// [lines] joined by newlines, through the engine's secret redactor
  /// (LOG-10, 03 §8.9), which the app cannot import; null when the engine
  /// has stopped, so nothing is exported unredacted by accident.
  Future<String?> redactLines(List<String> lines) {
    final requestId = 'redact-${_nextRedaction++}';
    return _redactions.read(
      requestId,
      RedactLines(requestId, lines),
      () => null,
    );
  }

  /// Checks [endpoints]' certificates from this device through the engine
  /// (CRT-01), which owns the sockets; null when the engine has stopped.
  Future<List<TlsEndpointCheck>?> checkTlsEndpoints(
    List<TlsEndpoint> endpoints,
  ) {
    final requestId = 'tls-${_nextTlsCheck++}';
    return _tlsChecks.read(
      requestId,
      CheckTlsEndpoints(requestId, endpoints),
      () => null,
    );
  }

  /// Reads [query] on [serverId]: a unit's file, its resources or the
  /// sockets (03 §7.5, SVC-07, SVC-08, SVC-10). A stopped engine answers
  /// no link.
  Future<UnitQueryResult> queryUnit(String serverId, UnitQuerySpec query) {
    final requestId = 'unit-${_nextUnitQuery++}';
    return _unitQueries.read(
      requestId,
      UnitQuery(serverId: serverId, requestId: requestId, query: query),
      () => _noUnitLink(serverId, requestId),
    );
  }

  static HostResult _noHostLink(String serverId, String queryId) => HostResult(
    serverId: serverId,
    queryId: queryId,
    payload: const HostQueryFailed(HostQueryFailure.noLink),
  );

  static UnitQueryResult _noUnitLink(String serverId, String requestId) =>
      UnitQueryResult(
        serverId: serverId,
        requestId: requestId,
        payload: const UnitQueryFailed(UnitQueryFailure.noLink),
      );

  void dispose() {
    _hostQueries.dispose();
    _unitQueries.dispose();
    _redactions.dispose();
    _tlsChecks.dispose();
  }
}
