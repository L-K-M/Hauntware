import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/server_links.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_core/seance_core.dart';

/// A server's link to itself opens on this device through a forward to the
/// server's own port; every other link opens as printed.
void main() {
  group('serverItselfHost', () {
    test('names the loopback hosts a server prints about itself', () {
      for (final (link, host) in [
        ('http://localhost:3000/', 'localhost'),
        ('http://app.localhost:5173/', 'app.localhost'),
        ('http://127.0.0.1:8000/docs', '127.0.0.1'),
        ('http://127.1.2.3/', '127.1.2.3'),
        ('http://[::1]:8080/', '::1'),
        ('http://0.0.0.0:8000/', '127.0.0.1'),
        ('http://[::]:8000/', '::1'),
        ('https://LOCALHOST:8443/', 'localhost'),
      ]) {
        expect(serverItselfHost(Uri.parse(link)), host, reason: link);
      }
    });

    test('leaves other hosts and schemes alone', () {
      for (final link in [
        'https://example.com/',
        'http://10.0.0.5:3000/',
        'http://127.example.com/',
        'http://localhost.example.com/',
        'ftp://localhost/',
      ]) {
        expect(serverItselfHost(Uri.parse(link)), isNull, reason: link);
      }
    });

    test('keeps the path, query and localhost name through the forward', () {
      for (final (link, here) in [
        ('http://localhost:3000/a/b?c=1#d', 'http://localhost:41234/a/b?c=1#d'),
        ('https://app.localhost:8443/', 'https://app.localhost:41234/'),
        ('http://127.0.0.1:8000/docs', 'http://127.0.0.1:41234/docs'),
        ('http://[::1]:8080/', 'http://127.0.0.1:41234/'),
        ('http://0.0.0.0:8000/', 'http://127.0.0.1:41234/'),
      ]) {
        expect(
          throughLoopback(Uri.parse(link), 41234).toString(),
          here,
          reason: link,
        );
      }
    });
  });

  group('TerminalSession.openableHere', () {
    const server = ServerConfig(
      id: 'box',
      label: 'box',
      host: 'box.example.com',
      username: 'deploy',
      createdAt: 1,
      updatedAt: 1,
    );

    TerminalSession tab({ServerConfig? config}) => TerminalSession(
      id: 'tab',
      serverId: config?.id ?? kLocalShellServerId,
      config: config,
      engine: XtermTerminalEngine(),
    );

    test('opens a server\'s own link through a forward to its port', () async {
      final session = tab(config: server);
      final transport = _ForwardingSession(session.engine);
      session.session = transport;
      addTearDown(transport.closeForwards);

      final here = await session.openableHere(
        Uri.parse('http://localhost:3000/app?x=1'),
      );

      expect(transport.targets, [('localhost', 3000)]);
      expect(here!.host, 'localhost');
      expect(here.port, transport.forwards.single.port);
      expect(here.path, '/app');
      expect(here.query, 'x=1');
    });

    test('opens any other link as printed', () async {
      final session = tab(config: server);
      session.session = _ForwardingSession(session.engine);

      expect(
        await session.openableHere(Uri.parse('https://example.com/')),
        isNull,
      );
    });

    test('leaves a local shell\'s localhost alone', () async {
      expect(
        await tab().openableHere(Uri.parse('http://localhost:3000/')),
        isNull,
      );
    });

    test('refuses while the server is disconnected', () async {
      await expectLater(
        tab(config: server).openableHere(Uri.parse('http://localhost:3000/')),
        throwsA(isA<StateError>()),
      );
    });
  });
}

/// A connected session whose forwards relay nowhere.
class _ForwardingSession implements SshSession {
  _ForwardingSession(this.engine);

  @override
  final TerminalEngine engine;

  final targets = <(String, int)>[];
  final forwards = <LoopbackForward>[];

  @override
  bool get isClosed => false;

  @override
  Future<LoopbackForward> forwardToLoopback(String host, int port) async {
    targets.add((host, port));
    final forward = await LoopbackForward.bind(
      () async => throw StateError('no target'),
    );
    forwards.add(forward);
    return forward;
  }

  Future<void> closeForwards() async {
    for (final forward in forwards) {
      await forward.close();
    }
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
