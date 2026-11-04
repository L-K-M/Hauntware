import 'dart:io' show HttpConnectionInfo, InternetAddress;

import 'package:shelf/shelf.dart';

/// Resolves the network source used by authentication rate limits.
///
/// Forwarded headers are trusted only when the immediate socket peer is an
/// explicitly configured proxy. Trust is exact-IP only; hostnames and CIDR
/// expansion belong in the deployment's proxy/firewall configuration.
final class RequestSourceResolver {
  const RequestSourceResolver({this.trustedProxies = const {}});

  final Set<String> trustedProxies;

  String call(Request request) {
    final connection =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    final immediate = connection?.remoteAddress.address;
    if (immediate == null) return 'unknown';
    if (!trustedProxies.contains(immediate)) return immediate;

    final forwarded = request.headers['x-forwarded-for'];
    if (forwarded == null || forwarded.trim().isEmpty) return immediate;
    final chain = <String>[];
    for (final raw in forwarded.split(',')) {
      final parsed = InternetAddress.tryParse(raw.trim());
      if (parsed == null) return immediate;
      chain.add(parsed.address);
    }
    for (final address in chain.reversed) {
      if (!trustedProxies.contains(address)) return address;
    }
    return chain.first;
  }
}
