import 'package:poltergeist_sync/poltergeist_sync.dart';

/// The pair-editor destination requested by a plan-view action.
enum SyncRulesEditTarget { general, docrootTrash, maxDelete }

final class SyncRulesEditRequest {
  const SyncRulesEditRequest.general()
    : target = SyncRulesEditTarget.general,
      docrootWarning = null;

  const SyncRulesEditRequest.docroot(this.docrootWarning)
    : target = SyncRulesEditTarget.docrootTrash;

  const SyncRulesEditRequest.maxDelete()
    : target = SyncRulesEditTarget.maxDelete,
      docrootWarning = null;

  final SyncRulesEditTarget target;
  final SyncDocrootWarning? docrootWarning;
}
