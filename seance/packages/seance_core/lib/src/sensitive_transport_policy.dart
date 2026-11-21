import 'dart:io';

/// Secrets and private data require TLS outside this device.
/// Numeric loopback addresses and localhost still support local development
/// and a local reverse proxy or tunnel.
bool isAllowedSensitiveTransport(Uri uri) {
  if (uri.host.isEmpty) return false;
  if (uri.scheme == 'https') return true;
  if (uri.scheme != 'http') return false;
  if (uri.host == 'localhost') return true;
  return InternetAddress.tryParse(uri.host)?.isLoopback ?? false;
}

String requireSensitiveTransportBaseUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !isAllowedSensitiveTransport(uri) ||
      uri.userInfo.isNotEmpty) {
    throw ArgumentError('Use HTTPS or local loopback HTTP for baseUrl');
  }
  return url;
}
