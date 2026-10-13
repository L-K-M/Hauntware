import 'api_version.dart';

/// Base of every failure this package reports (03 §5.5).
class DockerException implements Exception {
  const DockerException(this.message, {this.cause});

  final String message;

  /// The underlying error, when one exists (for example a stream error
  /// reported by the duplex).
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'DockerException: $message'
      : 'DockerException: $message (cause: $cause)';
}

/// The duplex could not carry the request: opener failure, write error,
/// premature EOF or remote close mid-message.
class DockerTransportException extends DockerException {
  const DockerTransportException(super.message, {super.cause});

  @override
  String toString() =>
      'DockerTransportException: $message'
      '${cause == null ? '' : ' (cause: $cause)'}';
}

/// The caller cancelled the request (or its body stream); the duplex was
/// closed as a result.
class DockerCancelledException extends DockerException {
  const DockerCancelledException(super.message);
}

/// The per-request timeout elapsed (03 §5.5: per-request timeouts for
/// short calls).
class DockerTimeoutException extends DockerException {
  const DockerTimeoutException(this.timeout)
    : super('request timed out after $timeout');

  final Duration timeout;
}

/// The peer sent malformed HTTP: bad status line or headers, a header
/// block over the cap, a malformed chunk size, a truncated body.
class DockerProtocolException extends DockerException {
  const DockerProtocolException(super.message, {super.cause});

  @override
  String toString() =>
      'DockerProtocolException: $message'
      '${cause == null ? '' : ' (cause: $cause)'}';
}

/// A buffered body grew past its `maxBytes` cap.
class DockerBodyTooLargeException extends DockerException {
  const DockerBodyTooLargeException(this.maxBytes)
    : super('response body exceeded the $maxBytes byte cap');

  final int maxBytes;
}

/// The daemon answered with an error status. [daemonMessage] keeps the
/// `message` field of the daemon's JSON error body when present.
class DockerApiException extends DockerException {
  const DockerApiException(this.statusCode, String? daemonMessage)
    : daemonMessage = daemonMessage,
      super(daemonMessage ?? 'HTTP $statusCode');

  final int statusCode;
  final String? daemonMessage;

  @override
  String toString() =>
      'DockerApiException($statusCode): ${daemonMessage ?? message}';
}

/// 400 without a version-shaped message: the request itself was rejected.
class DockerBadRequestException extends DockerApiException {
  const DockerBadRequestException(super.statusCode, super.daemonMessage);
}

/// 400 carrying the daemon's "client version is too new" message
/// (03 §5.5: typed failures for 400/version). [clientVersion] and
/// [serverMaxVersion] are parsed out when the daemon reports them.
class DockerVersionException extends DockerApiException {
  const DockerVersionException(
    super.statusCode,
    super.daemonMessage, {
    this.clientVersion,
    this.serverMaxVersion,
  });

  final ApiVersion? clientVersion;
  final ApiVersion? serverMaxVersion;
}

/// 404: the object is gone; the caller should refresh (03 §5.5).
class DockerNotFoundException extends DockerApiException {
  const DockerNotFoundException(super.statusCode, super.daemonMessage);
}

/// 409: conflict; the daemon's message is kept for display (03 §5.5).
class DockerConflictException extends DockerApiException {
  const DockerConflictException(super.statusCode, super.daemonMessage);
}

/// 5xx: the daemon failed.
class DockerServerException extends DockerApiException {
  const DockerServerException(super.statusCode, super.daemonMessage);
}

/// Any other non-success status (for example unexpected 3xx).
class DockerUnexpectedStatusException extends DockerApiException {
  const DockerUnexpectedStatusException(super.statusCode, super.daemonMessage);
}

/// Why version negotiation refused the engine (03 §5.8).
enum NegotiationRefusal {
  /// Neither `_ping` nor `/version` reported a parseable API version.
  serverVersionUnknown,

  /// `min(clientMax, serverMax)` fell below the client floor 1.41: the
  /// engine is too old for this client.
  belowClientFloor,

  /// `min(clientMax, serverMax)` fell below the server's `MinAPIVersion`:
  /// the engine rejects every version this client was tested against.
  belowServerMinimum,
}

/// Version negotiation refused the engine (03 §5.8).
class NegotiationRefusedException extends DockerException {
  NegotiationRefusedException(
    this.reason, {
    this.serverMax,
    this.serverMin,
    this.negotiated,
  }) : super(_buildMessage(reason, serverMax, serverMin, negotiated));

  final NegotiationRefusal reason;
  final ApiVersion? serverMax;
  final ApiVersion? serverMin;
  final ApiVersion? negotiated;

  static String _buildMessage(
    NegotiationRefusal reason,
    ApiVersion? serverMax,
    ApiVersion? serverMin,
    ApiVersion? negotiated,
  ) => switch (reason) {
    NegotiationRefusal.serverVersionUnknown =>
      'the engine did not report a parseable API version',
    NegotiationRefusal.belowClientFloor =>
      'the engine API version $serverMax is below the client floor '
          '$clientApiFloor',
    NegotiationRefusal.belowServerMinimum =>
      'the negotiated version $negotiated is below the server minimum '
          '$serverMin',
  };
}
