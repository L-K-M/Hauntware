import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A 32-byte subkey of [key] for [domain], by HKDF-SHA256.
///
/// `cryptography` 2.9's `Hkdf` exposes the salt but not RFC 5869's `info`
/// field, so the domain string is the salt: distinct salts yield independent
/// output key material, which is the separation the callers need. Internal to
/// this package; not exported.
Future<Uint8List> hkdfSubkey(List<int> key, String domain) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final derived = await hkdf.deriveKey(
    secretKey: SecretKey(key),
    nonce: utf8.encode(domain),
  );
  return Uint8List.fromList(await derived.extractBytes());
}
