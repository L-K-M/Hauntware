import 'dart:math';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

void main() {
  group('secret key rule (03 §8.9)', () {
    test('matches the documented patterns case-insensitively', () {
      for (final key in [
        'DB_PASSWORD',
        'postgres_password',
        'API_TOKEN',
        'PRIVATE_KEY',
        'AWS_SECRET_ACCESS_KEY',
        'AUTH_HEADER',
        'DSN',
        'DATABASE_URL',
        'CREDENTIALS',
      ]) {
        expect(isSecretKey(key), isTrue, reason: key);
      }
      expect(isSecretKey('APP_MODE'), isFalse);
      expect(isSecretKey('PATH'), isFalse);
      expect(isSecretKey('org.opencontainers.image.title'), isFalse);
    });

    test('over-matches KEY on purpose', () {
      expect(isSecretKey('MONKEY'), isTrue);
    });
  });

  group('MaskedValue', () {
    test('plain values render as-is and reveal nothing new', () {
      final v = MaskedValue.plain('production');
      expect(v.isMasked, isFalse);
      expect(v.display, 'production');
      expect(v.toString(), 'production');
      expect(v.reveal(), isNull);
    });

    test('secret values render the mask and reveal the text explicitly', () {
      final v = MaskedValue.secret('hunter2');
      expect(v.isMasked, isTrue);
      expect(v.display, MaskedValue.maskToken);
      expect(v.toString(), MaskedValue.maskToken);
      expect(v.reveal(), 'hunter2');
    });

    test('redacted values keep a safe display and the original', () {
      final v = MaskedValue.redacted('user:********@', 'user:pw@');
      expect(v.isMasked, isTrue);
      expect(v.display, 'user:********@');
      expect(v.reveal(), 'user:pw@');
    });
  });

  group('masking helpers', () {
    test('maskedLabels masks only secret keys', () {
      final labels = maskedLabels({
        'com.docker.compose.project': 'web',
        'API_TOKEN': 'x',
      });
      expect(labels['com.docker.compose.project']!.isMasked, isFalse);
      expect(labels['API_TOKEN']!.isMasked, isTrue);
    });

    test('maskedEnvEntry splits at the first equals', () {
      expect(maskedEnvEntry('A=B=C').reveal(), isNull);
      expect(maskedEnvEntry('SECRET=B=C').reveal(), 'B=C');
      expect(maskedEnvEntry('BARE').display, 'BARE');
    });

    test('maskUrlCredentials hides the password only', () {
      expect(
        maskUrlCredentials('postgres://admin:s3cr3t@db:5432/app'),
        'postgres://admin:${MaskedValue.maskToken}@db:5432/app',
      );
      expect(maskUrlCredentials('no url here'), 'no url here');
    });

    test('maskUrlCredentials masks what the rule as one regular '
        'expression masks', () {
      // The rule as it reads in 03 §8.9, which backtracks over each start
      // in a run of scheme characters.
      final rule = RegExp(
        r'([A-Za-z][A-Za-z0-9+.\-]*://)([^/@\s:]+):([^/@\s]+)@',
      );
      final random = Random(89);
      const pieces = ['a', 'Z', '1', '+', '-', '.', ':', '/', '@', ' '];
      const urls = ['://', 'u:p@', 'ab://u:p@h/', '\t'];
      for (var i = 0; i < 20000; i++) {
        final text = [
          for (var n = random.nextInt(12); n > 0; n--)
            random.nextInt(4) == 0
                ? urls[random.nextInt(urls.length)]
                : pieces[random.nextInt(pieces.length)],
        ].join();
        expect(
          maskUrlCredentials(text),
          text.replaceAllMapped(
            rule,
            (m) => '${m[1]}${m[2]}:${MaskedValue.maskToken}@',
          ),
          reason: text,
        );
      }
    });

    test('maskUrlCredentials takes time linear in the text', () {
      // A user on a monitored host controls process arguments of up to
      // 128 KiB each (Linux's MAX_ARG_STRLEN); a match that restarts at
      // each scheme character takes minutes over one.
      final watch = Stopwatch()..start();
      for (final text in [
        'a' * 131072,
        '${'a' * 131072}://',
        '${'a' * 65536}://u:${'p' * 65536}',
        'a://' * 32768,
        'a://u:' * 21845,
      ]) {
        expect(maskUrlCredentials(text), text);
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('maskedValueWithUrlCheck masks a URL even under a plain key', () {
      final v = maskedValueWithUrlCheck(
        'ENDPOINT',
        'https://user:pw@example.test/x',
      );
      expect(v.isMasked, isTrue);
      expect(v.display, contains(MaskedValue.maskToken));
      expect(v.reveal(), 'https://user:pw@example.test/x');
    });
  });
}
