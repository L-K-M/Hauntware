// CRT-01's endpoint TLS expiry (03 §7.10): a TLS handshake from this
// device to a host and port the user listed, which reads the certificate
// the endpoint presents. The vantage point is the device, not the
// server, and no SSH is involved.
import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

/// How long one check may take, connection and handshake together [E].
const kTlsCheckTimeout = Duration(seconds: 10);

/// The most endpoints one server lists [E]; each check is one connection
/// from the device.
const kTlsEndpointsMax = 20;

/// The port an endpoint listed without one is checked on.
const kTlsDefaultPort = 443;

/// One host and port whose certificate the device checks (CRT-01).
@immutable
final class TlsEndpoint {
  const TlsEndpoint(this.host, this.port);

  /// A host name or an IP address, without brackets.
  final String host;
  final int port;

  /// `host:port`, with an IPv6 address in brackets.
  String get label => host.contains(':') ? '[$host]:$port' : '$host:$port';

  /// [text] as an endpoint: `host`, `host:port`, `[v6]:port` or a bare
  /// IPv6 address, the port [kTlsDefaultPort] where it names none; or
  /// null when it is none of those.
  static TlsEndpoint? parse(String text) {
    final value = text.trim();
    if (value.isEmpty) return null;

    String host;
    String? port;
    if (value.startsWith('[')) {
      final close = value.indexOf(']');
      if (close < 0) return null;
      host = value.substring(1, close);
      final rest = value.substring(close + 1);
      if (rest.isNotEmpty) {
        if (!rest.startsWith(':')) return null;
        port = rest.substring(1);
      }
      if (InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6) {
        return null;
      }
    } else if (value.indexOf(':') != value.lastIndexOf(':')) {
      // Two colons or more: a bare IPv6 address.
      if (InternetAddress.tryParse(value) == null) return null;
      host = value;
    } else {
      final colon = value.indexOf(':');
      host = colon < 0 ? value : value.substring(0, colon);
      if (colon >= 0) port = value.substring(colon + 1);
      if (!_hostName.hasMatch(host)) return null;
    }

    final number = port == null ? kTlsDefaultPort : int.tryParse(port);
    if (number == null || number < 1 || number > 65535) return null;
    return TlsEndpoint(host.toLowerCase(), number);
  }

  /// A DNS name or a dotted IPv4 address: letters, digits, hyphens and
  /// dots, at most 253 characters.
  static final _hostName = RegExp(
    r'^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$',
  );

  @override
  bool operator ==(Object other) =>
      other is TlsEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => label;
}

/// Why a check read no certificate.
enum TlsCheckFailure {
  /// The host name did not resolve.
  lookup,

  /// No connection: refused, unreachable or reset.
  connect,

  /// No answer within [kTlsCheckTimeout].
  timeout,

  /// The endpoint connected but no TLS handshake completed, as for a
  /// port that does not speak TLS.
  handshake,
}

/// The certificate an endpoint presented.
@immutable
final class TlsCertificateFacts {
  const TlsCertificateFacts({
    required this.subject,
    required this.issuer,
    required this.notBefore,
    required this.notAfter,
  });

  /// As the TLS library prints them, `/CN=example.com`.
  final String subject, issuer;
  final DateTime notBefore, notAfter;
}

/// One endpoint's check.
@immutable
final class TlsEndpointCheck {
  const TlsEndpointCheck({
    required this.endpoint,
    this.certificate,
    this.trusted = false,
    this.failure,
    this.detail,
  });

  final TlsEndpoint endpoint;

  /// What the endpoint presented, or null when the check failed.
  final TlsCertificateFacts? certificate;

  /// Whether this device's trust store accepts the certificate for the
  /// host name: false for a self-signed, expired or mismatched one.
  final bool trusted;

  final TlsCheckFailure? failure;

  /// The error behind [failure], for its detail line.
  final String? detail;
}

/// Checks [endpoint] once: connects, completes a handshake that accepts
/// any certificate so a bad one can still be read, and notes whether the
/// device would have trusted it. Throws no exception; every failure is
/// typed.
Future<TlsEndpointCheck> checkTlsEndpoint(
  TlsEndpoint endpoint, {
  Duration timeout = kTlsCheckTimeout,
  SecurityContext? context,
}) async {
  TlsEndpointCheck failed(TlsCheckFailure failure, Object error) =>
      TlsEndpointCheck(
        endpoint: endpoint,
        failure: failure,
        detail: error.toString(),
      );

  var trusted = true;
  final deadline = Stopwatch()..start();
  // The raw socket is the check's own, so a handshake that never
  // answers is torn down with it (a [Socket] handed to
  // [SecureSocket.secure] is detached, and destroying it closes nothing);
  // one deadline bounds connection and handshake together.
  RawSocket? plain;
  RawSecureSocket? socket;
  try {
    plain = await RawSocket.connect(
      endpoint.host,
      endpoint.port,
      timeout: timeout,
    );
    final connected = plain;
    final secure = RawSecureSocket.secure(
      connected,
      host: endpoint.host,
      context: context,
      onBadCertificate: (_) {
        trusted = false;
        return true;
      },
    );
    final left = timeout - deadline.elapsed;
    socket = await secure.timeout(
      left.isNegative ? Duration.zero : left,
      onTimeout: () {
        unawaited(connected.close());
        // A handshake that completes after the timeout is closed at once.
        unawaited(
          secure.then<void>((late) => late.close(), onError: (Object _) {}),
        );
        throw TimeoutException('No TLS handshake', timeout);
      },
    );
    final certificate = socket.peerCertificate;
    if (certificate == null) {
      return failed(TlsCheckFailure.handshake, 'no certificate presented');
    }
    return TlsEndpointCheck(
      endpoint: endpoint,
      certificate: TlsCertificateFacts(
        subject: certificate.subject,
        issuer: certificate.issuer,
        notBefore: certificate.startValidity.toUtc(),
        notAfter: certificate.endValidity.toUtc(),
      ),
      trusted: trusted,
    );
  } on TimeoutException catch (error) {
    return failed(TlsCheckFailure.timeout, error);
  } on TlsException catch (error) {
    return failed(TlsCheckFailure.handshake, error);
  } on SocketException catch (error) {
    if (error.message.contains('timed out')) {
      return failed(TlsCheckFailure.timeout, error);
    }
    // dart:io names a resolver failure "Failed host lookup".
    if (error.message.contains('host lookup')) {
      return failed(TlsCheckFailure.lookup, error);
    }
    return failed(TlsCheckFailure.connect, error);
  } on Exception catch (error) {
    // dart:io may raise others (an OSError, a trust store's
    // FileSystemException); the check still answers.
    return failed(TlsCheckFailure.connect, error);
  } finally {
    if (socket != null) {
      unawaited(socket.close());
    } else {
      unawaited(plain?.close());
    }
  }
}
