import 'package:seance_protocol/seance_protocol.dart';

/// The account side of the inbox endpoints: everything Séance does with its
/// logged-in session. The producer's endpoint is not here; Séance never
/// deposits.
abstract class InboxApi {
  /// Throws [ApiError] `app_exists` if the id is taken.
  Future<void> createApp(CreateInboxAppRequest request);

  Future<List<InboxAppInfo>> listApps();

  /// Returns false if the server did not know the app.
  Future<bool> deleteApp(String appId);

  /// Pending items with `received > since`, oldest first.
  Future<List<InboxItem>> listItems({required int since});

  /// Returns false if the item was already gone, which during a claim means
  /// another device took it first.
  Future<bool> deleteItem(String appId, String itemId);
}
