import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

/// CRED-05's export: a vault sealed under its key, openable anywhere with
/// the recovery code, and refused for every way a code or a file can be
/// wrong.
void main() {
  final vaultKey = Uint8List.fromList(List.generate(32, (i) => i));
  final recoveryKey = Uint8List.fromList(List.generate(32, (i) => 200 - i));
  final code = RecoveryKey.encode(recoveryKey);
  final createdAt = DateTime.utc(2026, 10, 8, 12);

  final secrets = [
    const Secret(id: 'pw-web', kind: SecretKind.password, value: 'hunter2'),
    const Secret(
      id: 'key-db',
      kind: SecretKind.privateKey,
      value: '-----BEGIN KEY-----',
      keyPassphrase: 'pp',
      updatedAt: 42,
    ),
  ];

  late RecoveryWrapKey recovery;
  late Map<String, Uint8List> sealed;

  setUp(() async {
    recovery = await RecoveryWrapKey.derive(recoveryKey);
    sealed = {
      for (final secret in secrets)
        secret.id: await VaultCrypto.sealJson(vaultKey, secret.toJson()),
    };
  });

  Future<Uint8List> export([Map<String, Uint8List>? entries]) =>
      SecretsExport.build(
        recovery: recovery,
        vaultKey: vaultKey,
        sealedEntries: entries ?? sealed,
        createdAt: createdAt,
      );

  Map<String, dynamic> decode(List<int> bytes) =>
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

  List<int> encode(Map<String, dynamic> json) => utf8.encode(jsonEncode(json));

  Matcher fails(SecretsExportFailure failure) => throwsA(
    isA<SecretsExportException>().having((e) => e.failure, 'failure', failure),
  );

  /// [base64Text] with one bit of its decoded bytes flipped.
  String flipped(String base64Text, [int index = 0]) {
    final bytes = base64.decode(base64Text);
    bytes[index] ^= 0x01;
    return base64.encode(bytes);
  }

  group('RecoveryWrapKey', () {
    test(
      'is derived, not stored: same key, same wrap; JSON round trip',
      () async {
        final again = await RecoveryWrapKey.derive(recoveryKey);
        expect(again.wrapKey, recovery.wrapKey);
        expect(again.keyCheck, recovery.keyCheck);
        expect(recovery.wrapKey, isNot(recoveryKey));

        final restored = RecoveryWrapKey.fromJson(recovery.toJson());
        expect(restored.wrapKey, recovery.wrapKey);
        expect(restored.keyCheck, recovery.keyCheck);
      },
    );

    test('refuses keys of the wrong length and malformed entries', () async {
      await expectLater(
        RecoveryWrapKey.derive(Uint8List(16)),
        throwsArgumentError,
      );
      final json = recovery.toJson();
      expect(
        () => RecoveryWrapKey.fromJson({...json, 'version': 2}),
        throwsFormatException,
      );
      expect(
        () => RecoveryWrapKey.fromJson({
          ...json,
          'wrapKey': base64.encode(Uint8List(31)),
        }),
        throwsFormatException,
      );
    });

    test('reserved ids are the recovery namespace', () {
      expect(isReservedVaultId(recoveryWrapKeyId), isTrue);
      expect(isReservedVaultId('pw-web'), isFalse);
      expect(isReservedVaultId('inbox-key:app'), isFalse);
    });
  });

  group('SecretsExport', () {
    test('round trip: every credential comes back as it was', () async {
      final opened = await SecretsExport.open(await export(), code);

      expect(opened.createdAt, createdAt);
      expect(opened.unreadable, isEmpty);
      expect(opened.secrets.keys, unorderedEquals(['pw-web', 'key-db']));
      final key = opened.secrets['key-db']!;
      expect(key.kind, SecretKind.privateKey);
      expect(key.value, '-----BEGIN KEY-----');
      expect(key.keyPassphrase, 'pp');
      expect(key.updatedAt, 42);
    });

    test('the code may be typed loosely: case, spaces, no dashes', () async {
      final loose = code.toLowerCase().replaceAll('-', ' ');
      final opened = await SecretsExport.open(await export(), loose);
      expect(opened.secrets, hasLength(2));
    });

    test('holds no plaintext and leaves reserved entries out', () async {
      final bytes = await export({
        ...sealed,
        recoveryWrapKeyId: await VaultCrypto.sealJson(
          vaultKey,
          recovery.toJson(),
        ),
      });
      final text = utf8.decode(bytes);
      expect(text, isNot(contains('hunter2')));
      expect(text, isNot(contains('BEGIN KEY')));
      expect(decode(bytes)['entries'], isNot(contains(recoveryWrapKeyId)));
      expect(decode(bytes)['count'], 2);
    });

    test('a code from another key is the wrong code', () async {
      final other = RecoveryKey.encode(Uint8List(32));
      await expectLater(
        SecretsExport.open(await export(), other),
        fails(SecretsExportFailure.wrongCode),
      );
    });

    test('one mistyped symbol is not a code at all', () async {
      // Swap the first symbol for another in the alphabet.
      final typo = '${code[0] == '0' ? '1' : '0'}${code.substring(1)}';
      await expectLater(
        SecretsExport.open(await export(), typo),
        anyOf(
          fails(SecretsExportFailure.invalidCode),
          // A typo the 10-bit checksum misses still fails the key check.
          fails(SecretsExportFailure.wrongCode),
        ),
      );
      await expectLater(
        SecretsExport.open(await export(), 'not a code'),
        fails(SecretsExportFailure.invalidCode),
      );
    });

    test('a flipped bit anywhere authenticated is tampering', () async {
      final json = decode(await export());
      final cases = <String, Map<String, dynamic>>{
        'createdAt': {...json, 'createdAt': '2026-10-08T12:00:01.000Z'},
        'count+entry': {
          ...json,
          'count': 1,
          'entries': {'pw-web': (json['entries'] as Map)['pw-web']},
        },
        'entry': {
          ...json,
          'entries': {
            ...(json['entries'] as Map),
            'pw-web': flipped((json['entries'] as Map)['pw-web'] as String, 30),
          },
        },
        'mac': {...json, 'mac': flipped(json['mac'] as String)},
        'wrappedVaultKey': {
          ...json,
          'wrappedVaultKey': flipped(json['wrappedVaultKey'] as String, 30),
        },
      };
      for (final MapEntry(key: name, value: altered) in cases.entries) {
        await expectLater(
          SecretsExport.open(encode(altered), code),
          fails(SecretsExportFailure.tampered),
          reason: name,
        );
      }
    });

    test('an altered key check reads as the wrong code', () async {
      final json = decode(await export());
      await expectLater(
        SecretsExport.open(
          encode({...json, 'keyCheck': flipped(json['keyCheck'] as String)}),
          code,
        ),
        fails(SecretsExportFailure.wrongCode),
      );
    });

    test('member order does not change what is authenticated', () async {
      final json = decode(await export());
      final entries = json['entries'] as Map<String, dynamic>;
      final reordered = <String, dynamic>{
        'mac': json['mac'],
        'entries': {
          for (final id in entries.keys.toList().reversed) id: entries[id],
        },
        for (final MapEntry(:key, :value) in json.entries)
          if (key != 'mac' && key != 'entries') key: value,
      };
      final opened = await SecretsExport.open(encode(reordered), code);
      expect(opened.secrets, hasLength(2));
    });

    test('malformed files are refused before any decryption', () async {
      final bytes = await export();
      final json = decode(bytes);
      final cases = <String, List<int>>{
        'truncated': bytes.sublist(0, bytes.length ~/ 2),
        'not utf8': [0xFF, 0xFE, 0x00],
        'array': utf8.encode('[]'),
        'other format': encode({...json, 'format': 'other'}),
        'extra member': encode({...json, 'note': 'hi'}),
        'missing member': encode({...json}..remove('mac')),
        'count as double': utf8.encode(
          jsonEncode(json).replaceFirst('"count":2', '"count":2.0'),
        ),
        'count mismatch': encode({...json, 'count': 3}),
        'local time': encode({...json, 'createdAt': '2026-10-08T12:00:00'}),
        'unpadded base64': encode({
          ...json,
          'keyCheck': (json['keyCheck'] as String).replaceAll('=', ''),
        }),
        'non-string entry': encode({
          ...json,
          'entries': {...(json['entries'] as Map), 'pw-web': 7},
        }),
      };
      for (final MapEntry(key: name, value: altered) in cases.entries) {
        await expectLater(
          SecretsExport.open(altered, code),
          fails(SecretsExportFailure.malformed),
          reason: name,
        );
      }
    });

    test('a newer version is reported as such', () async {
      final json = decode(await export());
      await expectLater(
        SecretsExport.open(encode({...json, 'version': 2}), code),
        fails(SecretsExportFailure.unsupportedVersion),
      );
    });

    test('oversized files are refused before parsing', () async {
      await expectLater(
        SecretsExport.open(Uint8List(SecretsExport.maxBytes + 1), code),
        fails(SecretsExportFailure.tooLarge),
      );
      final json = decode(await export());
      await expectLater(
        SecretsExport.open(
          encode({...json, 'count': SecretsExport.maxEntries + 1}),
          code,
        ),
        fails(SecretsExportFailure.tooLarge),
      );
    });

    test('an entry the exporting vault could not read is skipped, '
        'not fatal', () async {
      final orphan = await VaultCrypto.sealJson(
        Uint8List(32),
        const Secret(id: 'old', kind: SecretKind.password, value: 'x').toJson(),
      );
      final mismatched = await VaultCrypto.sealJson(
        vaultKey,
        const Secret(
          id: 'elsewhere',
          kind: SecretKind.password,
          value: 'y',
        ).toJson(),
      );
      final opened = await SecretsExport.open(
        await export({...sealed, 'old': orphan, 'renamed': mismatched}),
        code,
      );
      expect(opened.secrets.keys, unorderedEquals(['pw-web', 'key-db']));
      expect(opened.unreadable, unorderedEquals(['old', 'renamed']));
    });

    test('an empty vault exports and opens', () async {
      final opened = await SecretsExport.open(await export({}), code);
      expect(opened.secrets, isEmpty);
    });
  });
}
