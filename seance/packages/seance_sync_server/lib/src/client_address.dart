import 'dart:io' show InternetAddress, InternetAddressType;
import 'dart:typed_data' show Uint8List;

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

/// Bits in an IPv4-mapped IPv6 address before the IPv4 part.
const int _ipv4MappedPrefixBits = 96;

final RegExp _prefixLength = RegExp(r'^[0-9]{1,3}$');

/// Returns the canonical spelling of a trusted proxy entry, or null when it is
/// not one.
///
/// An entry is a numeric address or a CIDR network such as `172.16.0.0/12`.
/// A network is spelled with its host bits cleared, a full-length network
/// folds to its plain address, and an IPv4-mapped IPv6 network becomes the
/// IPv4 network it covers, matching how [canonicalIpAddress] spells peers. A
/// zero-length network is refused: trusting every address would let any
/// caller choose its own rate-limit key.
String? canonicalTrustedProxy(String value) {
  final slash = value.indexOf('/');
  if (slash < 0) return canonicalIpAddress(value);

  final prefixText = value.substring(slash + 1);
  if (!_prefixLength.hasMatch(prefixText)) return null;
  final InternetAddress parsed;
  try {
    parsed = InternetAddress(value.substring(0, slash));
  } on ArgumentError {
    return null;
  }
  if (parsed.type == InternetAddressType.unix) return null;

  var raw = parsed.rawAddress;
  var prefix = int.parse(prefixText);
  if (prefix > raw.length * 8) return null;
  if (_isIpv4MappedIpv6(raw)) {
    if (prefix < _ipv4MappedPrefixBits) return null;
    raw = raw.sublist(12);
    prefix -= _ipv4MappedPrefixBits;
  }
  if (prefix == 0) return null;

  final network = _masked(raw, prefix);
  final address = InternetAddress.fromRawAddress(
    network,
    type: network.length == 4
        ? InternetAddressType.IPv4
        : InternetAddressType.IPv6,
  ).address;
  return prefix == network.length * 8 ? address : '$address/$prefix';
}

Uint8List _masked(List<int> raw, int prefix) {
  final out = Uint8List.fromList(raw);
  for (var index = 0; index < out.length; index++) {
    final bits = (prefix - index * 8).clamp(0, 8);
    out[index] &= (0xff << (8 - bits)) & 0xff;
  }
  return out;
}

/// One trusted proxy network; a single address is a full-length network.
class _TrustedNetwork {
  _TrustedNetwork(this._network, this._prefix);

  factory _TrustedNetwork.parse(String canonical) {
    final slash = canonical.indexOf('/');
    final address = InternetAddress(
      slash < 0 ? canonical : canonical.substring(0, slash),
    ).rawAddress;
    final prefix = slash < 0
        ? address.length * 8
        : int.parse(canonical.substring(slash + 1));
    return _TrustedNetwork(address, prefix);
  }

  final List<int> _network;
  final int _prefix;

  /// [address] is canonical, so a mapped IPv4 peer arrives as IPv4 and a
  /// family mismatch shows as a length mismatch.
  bool contains(String address) {
    final raw = InternetAddress(address).rawAddress;
    if (raw.length != _network.length) return false;
    final masked = _masked(raw, _prefix);
    for (var index = 0; index < masked.length; index++) {
      if (masked[index] != _network[index]) return false;
    }
    return true;
  }
}

/// Resolves the client address seen by a rate limiter.
///
/// Forwarded addresses are trusted only when the immediate peer is an
/// explicitly listed address or lies in a listed CIDR network. The chain is
/// walked from the nearest proxy towards the client; the first untrusted
/// address is the effective client. A malformed or excessive header falls
/// back to the immediate peer instead of letting the caller pick arbitrary
/// limiter keys.
class ClientAddressResolver {
  ClientAddressResolver(Iterable<String> trustedProxies)
    : _trustedProxies = [
        for (final proxy in trustedProxies)
          _TrustedNetwork.parse(
            canonicalTrustedProxy(proxy) ??
                (throw ArgumentError.value(
                  proxy,
                  'trustedProxies',
                  'must contain numeric IP addresses or CIDR networks',
                )),
          ),
      ];

  final List<_TrustedNetwork> _trustedProxies;

  bool _isTrusted(String address) =>
      _trustedProxies.any((network) => network.contains(address));

  String resolve({required String peerAddress, String? forwardedFor}) {
    final peer = canonicalIpAddress(peerAddress);
    if (peer == null) return 'unknown';
    if (!_isTrusted(peer) || forwardedFor == null || forwardedFor.isEmpty) {
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
      if (!_isTrusted(address)) return address;
    }
    return chain.first;
  }
}
