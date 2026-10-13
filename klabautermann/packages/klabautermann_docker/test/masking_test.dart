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
