// CRT-01's endpoint check (03 §7.10): the endpoint parser, and real
// handshakes against local servers: a self-signed TLS server, one that
// speaks no TLS, one that never answers, and a closed port. The TLS
// server's certificate is minted per run with openssl; without openssl
// those tests are skipped.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:klabautermann_core/src/certificates/tls_check.dart';
import 'package:test/test.dart';

void main() {
  group('parse', () {
    test('takes a host, a port and IPv6 in either form', () {
      expect(
        TlsEndpoint.parse('Example.com'),
        const TlsEndpoint('example.com', 443),
      );
      expect(
        TlsEndpoint.parse(' mail.example.com:993 '),
        const TlsEndpoint('mail.example.com', 993),
      );
      expect(
        TlsEndpoint.parse('192.0.2.1:8443'),
        const TlsEndpoint('192.0.2.1', 8443),
      );
      expect(
        TlsEndpoint.parse('[2001:db8::1]:8443'),
        const TlsEndpoint('2001:db8::1', 8443),
      );
      expect(
        TlsEndpoint.parse('2001:db8::1'),
        const TlsEndpoint('2001:db8::1', 443),
      );
      expect(const TlsEndpoint('2001:db8::1', 443).label, '[2001:db8::1]:443');
      expect(const TlsEndpoint('example.com', 443).label, 'example.com:443');
    });

    test('refuses anything else', () {
      for (final text in [
        '',
        'https://example.com',
        'example.com:0',
        'example.com:65536',
        'example.com:https',
        'exa mple.com',
        '-example.com',
        '[2001:db8::1',
        '[example.com]:443',
        '[2001:db8::1]443',
        '2001:db8::zz',
      ]) {
        expect(TlsEndpoint.parse(text), isNull, reason: text);
      }
    });
  });

  group('check', () {
    test(
      'reads a self-signed certificate and says it is not trusted',
      () async {
        final openssl = await _mint();
        if (openssl == null) {
          markTestSkipped('openssl is not installed');
          return;
        }
        final context = SecurityContext()
          ..useCertificateChain(openssl.cert)
          ..usePrivateKey(openssl.key);
        final server = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          context,
        );
        addTearDown(server.close);
        server.listen((socket) => socket.listen(null, onError: (_) {}));

        final check = await checkTlsEndpoint(
          TlsEndpoint('127.0.0.1', server.port),
        );
        expect(check.failure, isNull, reason: check.detail);
        expect(check.trusted, isFalse);
        expect(check.certificate!.subject, contains('klabautermann-test'));
        expect(
          check.certificate!.notAfter
              .difference(DateTime.now().toUtc())
              .inHours,
          inInclusiveRange(40, 48),
        );
      },
    );

    test('a handshake that completes after the timeout is closed, not '
        'leaked', () async {
      final openssl = await _mint();
      if (openssl == null) {
        markTestSkipped('openssl is not installed');
        return;
      }
      final context = SecurityContext()
        ..useCertificateChain(openssl.cert)
        ..usePrivateKey(openssl.key);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final closed = Completer<void>();
      server.listen((raw) async {
        // Answers the handshake only after the client gave up.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        final secure = await SecureSocket.secureServer(raw, context);
        secure.listen(
          null,
          onDone: closed.complete,
          onError: (Object _) => closed.complete(),
        );
      });

      final check = await checkTlsEndpoint(
        TlsEndpoint('127.0.0.1', server.port),
        timeout: const Duration(milliseconds: 300),
      );
      expect(check.failure, TlsCheckFailure.timeout);
      await closed.future.timeout(const Duration(seconds: 5));
    });

    test('a port that speaks no TLS fails the handshake', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) {
        socket.write('SSH-2.0-OpenSSH_9.6\r\n');
        unawaited(socket.close());
      });
      final check = await checkTlsEndpoint(
        TlsEndpoint('127.0.0.1', server.port),
      );
      expect(check.failure, TlsCheckFailure.handshake);
      expect(check.certificate, isNull);
    });

    test('an endpoint that never answers times out', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final held = <Socket>[];
      server.listen(held.add);
      addTearDown(() {
        for (final socket in held) {
          socket.destroy();
        }
      });
      final check = await checkTlsEndpoint(
        TlsEndpoint('127.0.0.1', server.port),
        timeout: const Duration(milliseconds: 300),
      );
      expect(check.failure, TlsCheckFailure.timeout);
    });

    test('a closed port does not connect', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final check = await checkTlsEndpoint(TlsEndpoint('127.0.0.1', port));
      expect(check.failure, TlsCheckFailure.connect);
      expect(check.detail, isNotNull);
    });
  });
}

/// A self-signed P-256 certificate and key valid for two days, or null
/// without openssl.
Future<({String cert, String key})?> _mint() async {
  final dir = await Directory.systemTemp.createTemp('klab-tls-');
  addTearDown(() => dir.delete(recursive: true));
  final cert = '${dir.path}/cert.pem';
  final key = '${dir.path}/key.pem';
  try {
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:prime256v1',
      '-nodes',
      '-days',
      '2',
      '-subj',
      '/CN=klabautermann-test',
      '-keyout',
      key,
      '-out',
      cert,
    ]);
    if (result.exitCode != 0) return null;
  } on ProcessException {
    return null;
  }
  return (cert: cert, key: key);
}
