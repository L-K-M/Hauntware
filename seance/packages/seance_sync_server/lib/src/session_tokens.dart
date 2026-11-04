import 'dart:convert';

import 'package:seance_protocol/seance_protocol.dart';

String hashSessionToken(String token) =>
    VaultCrypto.hashAuthVerifier(utf8.encode(token), const []);

String newSessionId() =>
    base64Url.encode(secureRandomBytes(16)).replaceAll('=', '');

void validateSessionPolicy(int now, int expiresAt, int maxSessions) {
  if (maxSessions <= 0) {
    throw ArgumentError.value(maxSessions, 'maxSessions', 'must be positive');
  }
  if (expiresAt <= now) {
    throw ArgumentError.value(expiresAt, 'expiresAt', 'must be after now');
  }
}
