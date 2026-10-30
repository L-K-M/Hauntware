/// Links a server prints about itself: `http://localhost:3000/` in a dev
/// server's banner names that server, not this device, so opening it here
/// as is would reach whatever this device runs on that port, or nothing.
library;

/// The host a link names when it is the machine that printed it, or null
/// for any other host. A wildcard address (`0.0.0.0`, `::`), which servers
/// print for "every interface", is reached at the matching loopback one.
String? serverItselfHost(Uri link) {
  if (link.scheme != 'http' && link.scheme != 'https') return null;
  final host = link.host.toLowerCase();
  if (host == 'localhost' || host.endsWith('.localhost')) return host;
  if (host == '0.0.0.0') return '127.0.0.1';
  if (host == '::') return '::1';
  if (host == '::1') return host;
  final octets = host.split('.');
  if (octets.length == 4 &&
      octets.first == '127' &&
      octets.every((octet) => int.tryParse(octet) != null)) {
    return host;
  }
  return null;
}

/// [link] as this device reaches it through a forward listening on
/// loopback [port]. A `localhost` name stays, so a certificate issued for
/// it, a `*.localhost` virtual host and cookies scoped to it still match;
/// browsers resolve it to the loopback address the forward listens on. An
/// address (`127.0.0.1`, `[::1]`, `0.0.0.0`) becomes `127.0.0.1`.
Uri throughLoopback(Uri link, int port) {
  final host = link.host.toLowerCase();
  final named = host == 'localhost' || host.endsWith('.localhost');
  return link.replace(host: named ? host : '127.0.0.1', port: port);
}
