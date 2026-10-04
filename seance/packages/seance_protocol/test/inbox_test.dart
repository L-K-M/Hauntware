import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

final DateTime _now = DateTime.utc(2026, 9, 29, 12);
final int _nowSeconds = _now.millisecondsSinceEpoch ~/ 1000;

Map<String, dynamic> _proposal([Map<String, dynamic> overrides = const {}]) => {
      'v': 1,
      'id': 'restart-worker-3',
      'host': 'prod-db-1',
      'title': 'Restart stuck queue worker',
      'reason': 'Backlog since 09:12',
      'script': 'systemctl restart queue-worker@3\nsystemctl status x',
      'created': _nowSeconds - 60,
      ...overrides,
    };

InboxProposal _parse(Map<String, dynamic> json) =>
    InboxProposal.parse(utf8.encode(jsonEncode(json)), now: _now);

void main() {
  group('InboxCrypto', () {
    final key = newInboxKey();
    final appId = newInboxAppId();

    test('round-trips and binds the blob to its key and app', () async {
      final blob = await InboxCrypto.seal(key, appId, utf8.encode('hello'));
      expect(blob.length, 24 + 5 + 16);
      expect(utf8.decode(await InboxCrypto.open(key, appId, blob)), 'hello');

      await expectLater(
        InboxCrypto.open(newInboxKey(), appId, blob),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        InboxCrypto.open(key, newInboxAppId(), blob),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      // A flipped byte in the nonce, the ciphertext and the tag.
      for (final at in [3, 25, 30]) {
        final tampered = Uint8List.fromList(blob)..[at] ^= 1;
        await expectLater(
          InboxCrypto.open(key, appId, tampered),
          throwsA(isA<SecretBoxAuthenticationError>()),
          reason: 'byte $at',
        );
      }
    });

    test('refuses a blob too short or too long to be a proposal', () async {
      await expectLater(
        InboxCrypto.open(key, appId, Uint8List(39)),
        throwsFormatException,
      );
      // Exactly the minimum is a box with no plaintext: it fails to
      // authenticate, not to parse.
      await expectLater(
        InboxCrypto.open(key, appId, Uint8List(40)),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        InboxCrypto.open(key, appId, Uint8List(kInboxMaxBlobBytes + 1)),
        throwsFormatException,
      );
    });

    test('opens a known libsodium vector', () async {
      // Sealed with PyNaCl's crypto_aead_xchacha20poly1305_ietf_encrypt
      // (nonce prepended), the construction the reference client uses:
      // key = bytes(range(32)), nonce = bytes(range(24)),
      // aad = b"seance/v1/inbox/AAAAAAAAAAAAAAAAAAAAAA", message = b"hi".
      final vector = base64.decode(_libsodiumVector);
      final clear = await InboxCrypto.open(
        List<int>.generate(32, (i) => i),
        'AAAAAAAAAAAAAAAAAAAAAA',
        vector,
      );
      expect(utf8.decode(clear), 'hi');
    });
  });

  group('InboxPairing', () {
    test('round-trips', () {
      final pairing = InboxPairing(
        url: 'https://sync.example.com/',
        appId: newInboxAppId(),
        token: newInboxToken(),
        key: newInboxKey(),
      );
      final text = pairing.encode();
      expect(text, startsWith('seance-inbox:'));
      expect(text, isNot(contains('=')));
      final back = InboxPairing.decode('  $text\n');
      expect(back.url, pairing.url);
      expect(back.appId, pairing.appId);
      expect(back.token, pairing.token);
      expect(back.key, pairing.key);
      expect(back.docsUrl, 'https://sync.example.com/llms.txt');
    });

    test('rejects other strings, damage and other versions', () {
      expect(() => InboxPairing.decode('hello'), throwsFormatException);
      expect(
        () => InboxPairing.decode('seance-inbox:!!!'),
        throwsFormatException,
      );
      String encode(Map<String, dynamic> json) =>
          'seance-inbox:${base64Url.encode(utf8.encode(jsonEncode(json)))}';
      final good = {
        'v': 1,
        'url': 'https://x',
        'app': newInboxAppId(),
        'token': newInboxToken(),
        'key': base64Url.encode(newInboxKey()).replaceAll('=', ''),
      };
      expect(InboxPairing.decode(encode(good)).url, 'https://x');
      expect(
        () => InboxPairing.decode(encode({...good, 'v': 2})),
        throwsFormatException,
      );
      expect(
        () => InboxPairing.decode(encode({...good, 'token': 'short'})),
        throwsFormatException,
      );
      expect(
        () => InboxPairing.decode(encode({...good, 'key': 'short'})),
        throwsFormatException,
      );
    });
  });

  group('InboxProposal', () {
    test('parses a valid proposal and defaults expiry to the cap', () {
      final p = _parse(_proposal());
      expect(p.id, 'restart-worker-3');
      expect(p.host, 'prod-db-1');
      expect(p.script, contains('\n'));
      expect(p.expires, p.created + kInboxRetention.inSeconds);
      expect(p.isExpiredAt(_now), isFalse);
    });

    test('caps expires at seven days and ignores unknown fields', () {
      final p = _parse(_proposal({
        'expires': _nowSeconds + 30 * 86400,
        'extra': {'x': 1},
      }));
      expect(p.expires, p.created + kInboxRetention.inSeconds);
      final short = _parse(_proposal({'expires': _nowSeconds + 10}));
      expect(short.expires, _nowSeconds + 10);
      expect(short.isExpiredAt(_now.add(const Duration(seconds: 10))), isTrue);
    });

    test('rejects malformed input', () {
      void rejects(Map<String, dynamic> json) => expect(
            () => _parse(json),
            throwsA(isA<InboxProposalException>()),
            reason: jsonEncode(json),
          );
      rejects(_proposal({'v': 2}));
      rejects(_proposal({'id': 'has space'}));
      rejects(_proposal({'id': 'x' * 65}));
      rejects(_proposal({'host': ''}));
      rejects(_proposal({'host': 'a\nb'}));
      rejects(_proposal({'host': 'x' * 201}));
      rejects(_proposal({'title': 'a\u2029b'}));
      for (final field in ['id', 'host', 'title', 'script', 'created']) {
        rejects({..._proposal()}..remove(field));
      }
      rejects(_proposal({'title': 'two\nlines'}));
      rejects(_proposal({'title': 'x' * 201}));
      rejects(_proposal({'reason': 'x' * 4001}));
      rejects(_proposal({'reason': 5}));
      rejects(_proposal({'script': '  '}));
      rejects(_proposal({'script': 'x' * (64 * 1024 + 1)}));
      rejects(_proposal({'created': _nowSeconds + 3600}));
      rejects(_proposal({'created': 'yesterday'}));
      rejects(_proposal({'expires': _nowSeconds - 3600}));
      expect(
        () => InboxProposal.parse(utf8.encode('[]'), now: _now),
        throwsA(isA<InboxProposalException>()),
      );
      expect(
        () => InboxProposal.parse([0xff, 0xfe], now: _now),
        throwsA(isA<InboxProposalException>()),
      );
    });
  });

  group('InboxApp', () {
    test('round-trips, and removal drops the key', () {
      final app = InboxApp(
        id: newInboxAppId(),
        name: 'bots',
        key: newInboxKey(),
        allowedServerIds: const ['a', 'b'],
        createdAt: 1,
        updatedAt: 2,
      );
      final back = InboxApp.fromJson(app.toJson());
      expect(back.key, app.key);
      expect(back.allowedServerIds, ['a', 'b']);
      expect(back.allowsServer('a'), isTrue);
      expect(back.allowsServer('c'), isFalse);
      expect(back.recordId, 'inboxapp:${app.id}');

      final removed = InboxApp.fromJson(app.asRemoved(updatedAt: 3).toJson());
      expect(removed.removed, isTrue);
      expect(removed.key, isNull);
      expect(removed.toJson().containsKey('key'), isFalse);
    });

    test('rejects a live app without a key and a removed one with a key', () {
      final id = newInboxAppId();
      expect(() => InboxApp.fromJson({'id': id}), throwsFormatException);
      expect(
        () => InboxApp.fromJson({'id': id, 'key': 'AAAA', 'removed': true}),
        throwsFormatException,
      );
      final key = base64Url.encode(newInboxKey()).replaceAll('=', '');
      expect(
        () => InboxApp.fromJson({'id': 'bad', 'key': key}),
        throwsFormatException,
      );
      expect(
        () => InboxApp.fromJson({'id': id, 'key': 'x'}),
        throwsFormatException,
      );
      expect(
        () => InboxApp.fromJson({'id': id, 'key': key, 'servers': 'all'}),
        throwsFormatException,
      );
      expect(
        () => InboxApp.fromJson({'id': id, 'key': key, 'servers': [1]}),
        throwsFormatException,
      );
      expect(
        () => InboxApp.fromJson({
          'id': id,
          'removed': true,
          'servers': ['s1'],
        }),
        throwsFormatException,
      );
    });
  });

  group('InboxStatus', () {
    test('round-trips and names its record', () {
      final appId = newInboxAppId();
      final status = InboxStatus(
        appId: appId,
        proposalId: 'p1',
        state: InboxStatusState.dismissed,
        updatedAt: 5,
      );
      final back = InboxStatus.fromJson(status.toJson());
      expect(back.state, InboxStatusState.dismissed);
      expect(back.recordId, 'inboxstatus:$appId:p1');
      expect(
        () => InboxStatus.fromJson({...status.toJson(), 'state': 'maybe'}),
        throwsFormatException,
      );
    });
  });

  test('a malformed inbox item is a FormatException', () {
    expect(
      () => InboxItem.fromJson({'app': 'a', 'item': 'i', 'blob': ''}),
      throwsFormatException,
    );
    expect(
      () => InboxItem.fromJson(
        {'app': 'a', 'item': 'i', 'received': '1', 'blob': ''},
      ),
      throwsFormatException,
    );
  });

  test('record kinds resolve by name', () {
    expect(recordKindFromName('inboxApp'), RecordKind.inboxApp);
    expect(recordKindFromName('inboxStatus'), RecordKind.inboxStatus);
  });
}

const String _libsodiumVector = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYX9qsLvAvYNNAPeYc6y/Cwu6pt';
