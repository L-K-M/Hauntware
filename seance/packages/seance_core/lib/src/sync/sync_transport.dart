/// The sync transport seam the apps drive enrollment and rounds over:
/// the catalog library's [SyncEnrollmentApi], plus the account deletion
/// and connection release only a concrete client can do.
///
/// Séance's own app has no use for this marker — it talks to
/// `HttpSyncClient` directly — but Poltergeist's backup service and
/// Klabautermann's engine both build one transport per server and pass
/// it to the shared enrollment code, so the marker and its factory live
/// here rather than being written once per product.
library;

import '../catalog/enrollment.dart' show SyncEnrollmentApi;
import 'http_sync_client.dart';

/// A [SyncEnrollmentApi] that can also delete the account it is signed
/// into and release its connections. `HttpSyncClient` already implements
/// every member, so [HttpSyncTransport] is a pure marker.
abstract interface class SyncTransport implements SyncEnrollmentApi {
  /// DELETE /v1/account.
  Future<void> deleteAccount();

  /// Release owned connections; the client cannot be reused afterwards.
  void close();
}

/// Builds the transport for [baseUrl]. [token] seeds a restored session;
/// enrollment calls pass none.
typedef SyncTransportFactory =
    SyncTransport Function(String baseUrl, {String? token});

/// The production binding: [HttpSyncClient] satisfies [SyncTransport]
/// wholesale, and the bearer token is a public field on the client, so
/// seeding it here lets a restored session authenticate without another
/// login.
final class HttpSyncTransport extends HttpSyncClient implements SyncTransport {
  HttpSyncTransport(
    String baseUrl, {
    String? token,
    super.deviceId,
    super.deviceName,
  }) : super(baseUrl: baseUrl) {
    this.token = token;
  }
}

/// The default [SyncTransportFactory]; tests substitute fakes.
SyncTransport httpSyncTransport(
  String baseUrl, {
  String? token,
  String? deviceId,
  String? deviceName,
}) => HttpSyncTransport(
  baseUrl,
  token: token,
  deviceId: deviceId,
  deviceName: deviceName,
);
