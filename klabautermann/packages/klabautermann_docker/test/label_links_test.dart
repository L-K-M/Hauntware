// CTR-11's label links: Dockhand's and Dozzle's URL labels, Traefik
// routers' Host rules and caddy-docker-proxy sites, each an http or https
// address without credentials, from unmasked values only.
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

Map<String, MaskedValue> _labels(Map<String, String> plain) => {
  for (final MapEntry(:key, :value) in plain.entries)
    key: MaskedValue.plain(value),
};

void main() {
  test('Dockhand and Dozzle URLs, a named one and a port\'s', () {
    final links = labelLinks(
      _labels({
        'dockhand.url': '[Admin](https://app.example.com/admin)',
        'dockhand.port.8080.url': 'http://10.0.0.5:8080',
        'dev.dozzle.url': 'https://logs.example.com',
      }),
    );
    expect(links.map((l) => '${l.uri}'), [
      'https://app.example.com/admin',
      'http://10.0.0.5:8080',
      'https://logs.example.com',
    ]);
    expect(links.first.name, 'Admin');
    expect(links[1].port, 8080);
    expect(links.map((l) => l.source), [
      LabelLinkSource.dockhand,
      LabelLinkSource.dockhand,
      LabelLinkSource.dozzle,
    ]);
  });

  test('a Traefik rule names each host, over HTTPS where the router '
      'serves TLS', () {
    final links = labelLinks(
      _labels({
        'traefik.http.routers.web.rule':
            'Host(`app.example.com`) || Host(`www.example.com`, "alt.example.com")',
        'traefik.http.routers.web.entrypoints': 'websecure',
        'traefik.http.routers.plain.rule':
            'Host(`plain.example.com`) && PathPrefix(`/api`)',
        'traefik.http.routers.wild.rule':
            'HostRegexp(`{sub:[a-z]+}.example.com`)',
      }),
    );
    expect(links.map((l) => '${l.uri}'), [
      'https://app.example.com',
      'https://www.example.com',
      'https://alt.example.com',
      'http://plain.example.com',
    ]);
    expect(links.every((l) => l.source == LabelLinkSource.traefik), isTrue);

    expect(
      labelLinks(
        _labels({
          'traefik.enable': 'false',
          'traefik.http.routers.web.rule': 'Host(`app.example.com`)',
        }),
      ),
      isEmpty,
    );
    expect(
      labelLinks(
        _labels({
          'traefik.http.routers.web.rule': 'Host(`app.example.com`)',
          'traefik.http.routers.web.tls.certresolver': 'le',
        }),
      ).single.uri.scheme,
      'https',
    );
  });

  test('caddy sites are HTTPS hosts or URLs; ports, wildcards and '
      'placeholders are skipped', () {
    final links = labelLinks(
      _labels({
        'caddy': 'example.com, www.example.com',
        'caddy_1': 'http://intranet.lan *.example.com {\$HOST} :8080',
      }),
    );
    expect(links.map((l) => '${l.uri}'), [
      'https://example.com',
      'https://www.example.com',
      'http://intranet.lan',
    ]);
  });

  test('no link from a masked value, another scheme, credentials or a '
      'relative address, and each address once', () {
    final links = labelLinks({
      'dockhand.url': MaskedValue.redacted(
        'https://${MaskedValue.maskToken}@app.example.com',
        'https://user:secret@app.example.com',
      ),
      'dev.dozzle.url': MaskedValue.plain('/logs'),
      'dockhand.port.22.url': MaskedValue.plain('ssh://host'),
      'dockhand.port.80.url': MaskedValue.plain('https://u:p@host.example'),
      'caddy': MaskedValue.plain('app.example.com'),
      'caddy_0': MaskedValue.plain('app.example.com'),
      'dockhand.port.99999.url': MaskedValue.plain('https://x.example'),
    });
    expect(links.map((l) => '${l.uri}'), ['https://app.example.com']);
  });
}
