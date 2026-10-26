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

  test('caddy sites are HTTPS hosts, with a port where given, or URLs; '
      'wildcards, placeholders and bare ports are skipped', () {
    final links = labelLinks(
      _labels({
        'caddy': 'example.com, www.example.com:8443, a.example:80',
        'caddy_1':
            'http://intranet.lan *.example.com {\$HOST} :8080 a.example:99999',
      }),
    );
    expect(links.map((l) => '${l.uri}'), [
      'https://example.com',
      'https://www.example.com:8443',
      'http://a.example',
      'http://intranet.lan',
    ]);
  });

  test('each rule rejects on its own', () {
    List<String> uris(Map<String, MaskedValue> labels) => [
      for (final link in labelLinks(labels)) '${link.uri}',
    ];

    // A masked value, even a well-formed address.
    expect(
      uris({
        'dockhand.url': MaskedValue.redacted(
          MaskedValue.maskToken,
          'https://app.example.com',
        ),
      }),
      isEmpty,
    );
    expect(uris({'dev.dozzle.url': MaskedValue.plain('/logs')}), isEmpty);
    expect(uris({'dockhand.url': MaskedValue.plain('ssh://host')}), isEmpty);
    // A wildcard or a placeholder, in any label that takes a URL.
    for (final address in [
      'https://*.example.com',
      'https://{host}/admin',
      'https://\${DOMAIN}',
      'https://<host>',
    ]) {
      expect(
        uris({
          'dockhand.url': MaskedValue.plain(address),
          'dev.dozzle.url': MaskedValue.plain(address),
          'caddy': MaskedValue.plain(address),
        }),
        isEmpty,
        reason: address,
      );
    }
    expect(uris({'dev.dozzle.url': MaskedValue.plain('http://[::1]:8080/')}), [
      'http://[::1]:8080/',
    ]);
    expect(
      uris({'dockhand.url': MaskedValue.plain('https://u:p@host.example')}),
      isEmpty,
    );
    // A port label outside 1 to 65535 names no port.
    expect(
      uris({'dockhand.port.99999.url': MaskedValue.plain('https://x.example')}),
      isEmpty,
    );
    expect(
      uris({
        'caddy': MaskedValue.plain('app.example.com'),
        'caddy_0': MaskedValue.plain('app.example.com'),
      }),
      ['https://app.example.com'],
    );
  });

  test('a blank Markdown name leaves the address as the title, and '
      'entry points match by name', () {
    expect(
      labelLinks(
        _labels({'dockhand.url': '[ ](https://app.example.com)'}),
      ).single.name,
      isNull,
    );
    expect(
      labelLinks(
        _labels({
          'traefik.http.routers.web.rule': 'Host(`app.example.com`)',
          'traefik.http.routers.web.entrypoints': 'api-https-proxy',
        }),
      ).single.uri.scheme,
      'http',
    );
    expect(
      labelLinks(
        _labels({
          'traefik.http.routers.web.rule': 'Host(`app.example.com`)',
          'traefik.http.routers.web.entrypoints': 'web, websecure',
        }),
      ).single.uri.scheme,
      'https',
    );
  });
}
