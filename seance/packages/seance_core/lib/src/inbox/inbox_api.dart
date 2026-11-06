import 'package:seance_protocol/seance_protocol.dart';

/// The account side of the inbox endpoints: everything Séance does with its
/// logged-in session. The producer's endpoint is not here; Séance never
/// deposits.
abstract class InboxApi {
  /// Throws [ApiError] `app_exists` if the id is taken.
  Future<void> createApp(CreateInboxAppRequest request);

  Future<List<InboxAppInfo>> listApps();

  /// Returns false only when the server itself says the app is unknown
  /// (`not_found`). Any other failure, a plain 404 from an older server or a
  /// proxy included, throws: reading it as "already gone" would let the app
  /// be forgotten here while its token still works.
  Future<bool> deleteApp(String appId);

  /// Pending items with `received > since`, oldest first.
  Future<List<InboxItem>> listItems({required int since});

  /// Returns false only when the server itself says the item is gone
  /// (`not_found`), which during a claim means another device took it first.
  /// Any other failure, a plain 404 included, throws: reading it as "taken"
  /// would drop a proposal nobody ran.
  Future<bool> deleteItem(String appId, String itemId);
}

/// Optional paged form of the inbox listing endpoint.
///
/// Kept separate from [InboxApi] so existing embeddings and test fakes that
/// implement that interface do not gain a new required member. Callers may
/// detect this interface at runtime and otherwise fall back to [InboxApi.listItems].
/// Implementations keep one server watermark across the stream and validate
/// that every yielded page makes monotonic progress.
abstract interface class PagedInboxApi {
  Stream<InboxPage> listItemPages({required int since});
}
