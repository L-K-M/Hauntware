// Stack file masking (03 §7.16 STK-04, §8.9; M11): every `.env` value,
// the compose map and list forms under a secret key, block scalars and
// URL credentials, with the real text kept behind each masked span.
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

String _shown(List<MaskedValue> spans) => spans.map((s) => s.display).join();

String _revealed(List<MaskedValue> spans) =>
    spans.map((s) => s.reveal() ?? s.display).join();

List<String> _secrets(List<MaskedValue> spans) => [
  for (final s in spans)
    if (s.isMasked) s.reveal()!,
];

const _m = MaskedValue.maskToken;

void main() {
  group('environment files', () {
    test('every value is masked, comments and blank lines are not', () {
      const text =
          '# database\n'
          'DB_PASSWORD=hunter2\n'
          '\n'
          'export TZ=UTC\n'
          'EMPTY=\n'
          'URL=postgres://app:pw@db/app\n';
      final spans = maskStackFile(text, StackFileKind.environment);

      expect(
        _shown(spans),
        '# database\n'
        'DB_PASSWORD=$_m\n'
        '\n'
        'export TZ=$_m\n'
        'EMPTY=\n'
        'URL=$_m\n',
      );
      expect(_secrets(spans), ['hunter2', 'UTC', 'postgres://app:pw@db/app']);
      expect(_revealed(spans), text);
    });

    test('a quoted value over several lines stays masked to its closing '
        'quote, and CRLF line endings stay plain', () {
      const text =
          'KEY="-----BEGIN\r\n'
          'abc\\"def\r\n'
          'END-----"\r\n'
          'NEXT=1\r\n';
      final spans = maskStackFile(text, StackFileKind.environment);

      expect(_shown(spans), 'KEY=$_m\r\n$_m\r\n$_m\r\nNEXT=$_m\r\n');
      expect(_revealed(spans), text);
    });

    test('a line that is no assignment masks its URL credentials only', () {
      final spans = maskStackFile(
        'see https://bob:s3cret@example.com',
        StackFileKind.environment,
      );
      expect(_shown(spans), 'see https://bob:$_m@example.com');
      expect(_secrets(spans), ['s3cret']);
    });
  });

  group('compose files', () {
    test('map form masks the values of secret keys only', () {
      const text =
          'services:\n'
          '  db:\n'
          '    image: postgres:16\n'
          '    environment:\n'
          '      POSTGRES_PASSWORD: hunter2\n'
          '      "API_TOKEN": "tok en"\n'
          '      POSTGRES_DB: app\n'
          '      SECRET_REF: # set below\n';
      final spans = maskStackFile(text, StackFileKind.compose);

      expect(
        _shown(spans),
        'services:\n'
        '  db:\n'
        '    image: postgres:16\n'
        '    environment:\n'
        '      POSTGRES_PASSWORD: $_m\n'
        '      "API_TOKEN": "$_m"\n'
        '      POSTGRES_DB: app\n'
        '      SECRET_REF: # set below\n',
      );
      expect(_secrets(spans), ['hunter2', 'tok en']);
      expect(_revealed(spans), text);
    });

    test('list form masks the values of secret keys only, keeping the '
        'closing quote', () {
      const text =
          '    environment:\n'
          '      - DB_PASSWORD=hunter2\n'
          "      - 'AUTH_KEY=a=b'\n"
          '      - MODE=prod\n';
      final spans = maskStackFile(text, StackFileKind.compose);

      expect(
        _shown(spans),
        '    environment:\n'
        '      - DB_PASSWORD=$_m\n'
        "      - 'AUTH_KEY=$_m'\n"
        '      - MODE=prod\n',
      );
      expect(_secrets(spans), ['hunter2', 'a=b']);
      expect(_revealed(spans), text);
    });

    test('a block scalar under a secret key is masked to its end', () {
      const text =
          '  PRIVATE_KEY: |\n'
          '    line one\n'
          '\n'
          '    line two\n'
          '  image: nginx\n';
      final spans = maskStackFile(text, StackFileKind.compose);

      expect(
        _shown(spans),
        '  PRIVATE_KEY: |\n'
        '    $_m\n'
        '\n'
        '    $_m\n'
        '  image: nginx\n',
      );
      expect(_revealed(spans), text);
    });

    test('URL credentials are masked under any key', () {
      const text = '      DATABASE_HOST: postgres://app:pw@db:5432/app\n';
      final spans = maskStackFile(text, StackFileKind.compose);

      expect(
        _shown(spans),
        '      DATABASE_HOST: postgres://app:$_m@db:5432/app\n',
      );
      expect(_secrets(spans), ['pw']);
    });

    test('a file without secrets is one plain span', () {
      const text = 'services:\n  web:\n    image: nginx\n';
      expect(maskStackFile(text, StackFileKind.compose), [
        MaskedValue.plain(text),
      ]);
    });
  });
}
