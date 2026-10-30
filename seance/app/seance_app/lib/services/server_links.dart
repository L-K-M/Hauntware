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
/// loopback [port].
Uri throughLoopback(Uri link, int port) =>
    link.replace(host: '127.0.0.1', port: port);
