import 'dart:io' show InternetAddress, InternetAddressType;

/// Maximum proxy hops accepted from `X-Forwarded-For`.
const int maxForwardedForHops = 32;

/// Maximum header characters accepted from `X-Forwarded-For`.
const int maxForwardedForLength = 2048;

/// Returns the platform's canonical spelling of a numeric IP address, or null
/// for a hostname, a Unix socket, or malformed input.
String? canonicalIpAddress(String value) {
  try {
    final address = InternetAddress(value);
    if (address.type == InternetAddressType.unix) return null;

    final rawAddress = address.rawAddress;
    if (_isIpv4MappedIpv6(rawAddress)) {
      return InternetAddress.fromRawAddress(
        rawAddress.sublist(12),
        type: InternetAddressType.IPv4,
      ).address;
    }

    return InternetAddress.fromRawAddress(
      rawAddress,
      type: address.type,
    ).address;
  } on ArgumentError {
    return null;
  }
}

bool _isIpv4MappedIpv6(List<int> rawAddress) {
  if (rawAddress.length != 16 ||
      rawAddress[10] != 0xff ||
      rawAddress[11] != 0xff) {
    return false;
  }

  for (var index = 0; index < 10; index++) {
    if (rawAddress[index] != 0) return false;
  }
  return true;
}

/// Resolves the client address seen by a rate limiter.
///
/// Forwarded addresses are trusted only when the immediate peer is explicitly
/// listed. The chain is walked from the nearest proxy towards the client; the
/// first untrusted address is the effective client. A malformed or excessive
/// header falls back to the immediate peer instead of letting the caller pick
/// arbitrary limiter keys.
class ClientAddressResolver {
  ClientAddressResolver(Iterable<String> trustedProxies)
    : _trustedProxies = {
        for (final proxy in trustedProxies)
          canonicalIpAddress(proxy) ??
              (throw ArgumentError.value(
                proxy,
                'trustedProxies',
                'must contain numeric IP addresses',
              )),
      };

  final Set<String> _trustedProxies;

  String resolve({required String peerAddress, String? forwardedFor}) {
    final peer = canonicalIpAddress(peerAddress) ?? 'unknown';
    if (!_trustedProxies.contains(peer) ||
        forwardedFor == null ||
        forwardedFor.isEmpty) {
      return peer;
    }
    if (forwardedFor.length > maxForwardedForLength) return peer;

    final parts = forwardedFor.split(',');
    if (parts.length > maxForwardedForHops) return peer;
    final chain = <String>[];
    for (final part in parts) {
      final address = canonicalIpAddress(part.trim());
      if (address == null) return peer;
      chain.add(address);
    }
    if (chain.isEmpty) return peer;

    for (final address in chain.reversed) {
      if (!_trustedProxies.contains(address)) return address;
    }
    return chain.first;
  }
}
