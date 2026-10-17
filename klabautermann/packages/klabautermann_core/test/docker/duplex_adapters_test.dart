// The Docker client's two duplexes (03 §3.3, §5.9): a streamlocal
// channel's half-close, and a relay process's stdin, stdout, bounded
// stderr and exit.
import 'dart:convert';

import 'package:klabautermann_core/src/docker/duplex_adapters.dart';
import 'package:klabautermann_docker/testing.dart';
import 'package:test/test.dart';

import '../support/forwarding_link.dart';

void main() {
  group('SshDuplexAdapter', () {
    test('closeWrite sends EOF and keeps reading', () async {
      final daemon = PingDaemon();
      final link = ForwardingLink()..daemons['/s'] = daemon;
      final duplex = SshDuplexAdapter(await link.openUnixStream('/s'));
      final received = duplex.stream.transform(latin1.decoder).join();

      duplex.sink.add(latin1.encode('HEAD /_ping HTTP/1.1\r\n\r\n'));
      await duplex.closeWrite();

      // The daemon answers after the EOF, then closes on it.
      expect(await received, startsWith('HTTP/1.1 200 OK'));
      await duplex.done;
      expect(daemon.requests, ['HEAD /_ping HTTP/1.1']);
      expect(daemon.closed, 1);
    });

    test('close ends both directions', () async {
      final daemon = PingDaemon();
      final link = ForwardingLink()..daemons['/s'] = daemon;
      final duplex = SshDuplexAdapter(await link.openUnixStream('/s'));

      await duplex.close();

      await duplex.done;
      expect(await duplex.stream.isEmpty, isTrue);
    });
  });

  group('ProcessDuplex', () {
    test('relays stdin and stdout; closeWrite is stdin EOF', () async {
      final pair = FakeDuplexPair();
      final process = RelayProcess(pair.client);
      final duplex = ProcessDuplex(process);
      final toDaemon = pair.server.stream.transform(latin1.decoder).join();
      final fromDaemon = duplex.stream.transform(latin1.decoder).join();

      duplex.sink.add(latin1.encode('request'));
      await duplex.closeWrite();
      expect(await toDaemon, 'request');

      // The read side still carries the daemon's bytes after stdin EOF.
      pair.server.sink.add(latin1.encode('response'));
      await pair.server.close();
      expect(await fromDaemon, 'response');
      await duplex.done;
      expect((await duplex.exit).exitCode, 0);
    });

    test('keeps the last stderr bytes for diagnostics', () async {
      final process = RelayProcess(FakeDuplexPair().client);
      final duplex = ProcessDuplex(process);
      expect(duplex.diagnostics, isEmpty);

      final noise = List.filled(kRelayStderrMaxBytes, 0x2e);
      await process.fail([
        ...noise,
        ...utf8.encode('Cannot connect to the Docker daemon'),
      ], exitCode: 1);
      await duplex.done;
      await pumpEventQueue();

      expect(duplex.diagnostics, hasLength(kRelayStderrMaxBytes));
      expect(
        duplex.diagnostics,
        endsWith('Cannot connect to the Docker daemon'),
      );
      expect((await duplex.exit).exitCode, 1);
    });

    test('the exit is the close: stdout ends with it', () async {
      final pair = FakeDuplexPair();
      final duplex = ProcessDuplex(RelayProcess(pair.client));
      final ended = duplex.stream.isEmpty;

      await pair.server.close();

      expect(await ended, isTrue);
      await duplex.done;
    });

    test('close closes the process', () async {
      final process = RelayProcess(FakeDuplexPair().client);
      final duplex = ProcessDuplex(process);

      await duplex.close();

      expect(process.closeCalls, 1);
      await duplex.done;
      expect((await duplex.exit).exitSignal, 'TERM');
    });
  });
}
