// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Poltergeist';

  @override
  String get menuFile => 'File';

  @override
  String get menuEdit => 'Edit';

  @override
  String get menuView => 'View';

  @override
  String get menuGo => 'Go';

  @override
  String get menuServer => 'Server';

  @override
  String get menuWindow => 'Window';

  @override
  String get menuHelp => 'Help';

  @override
  String get paneAName => 'Pane A';

  @override
  String get paneBName => 'Pane B';

  @override
  String get paneNoEngine => 'Browsing is unavailable right now.';

  @override
  String get paneNoLocation => 'This pane has no location open.';

  @override
  String get resizePanes => 'Resize panes';

  @override
  String paneRatioPercent(int value) {
    return '$value%';
  }

  @override
  String get readyStatus => 'Ready';

  @override
  String get hostKeyUnknownTitle => 'Unknown host key';

  @override
  String get hostKeyChangedTitle => 'HOST KEY CHANGED';

  @override
  String hostKeyChangedWarning(String host) {
    return 'The key for $host does not match the one you previously trusted. This can mean a man-in-the-middle attack. Only continue if you know why the key changed.';
  }

  @override
  String hostKeyEndpoint(String host, int port) {
    return '$host:$port';
  }

  @override
  String get hostKeyFingerprintLabel => 'Fingerprint';

  @override
  String get hostKeyNewLabel => 'New key';

  @override
  String get hostKeyPreviousLabel => 'Previously trusted';

  @override
  String get hostKeyCancel => 'Cancel';

  @override
  String get hostKeyTrustConnect => 'Trust and connect';

  @override
  String get hostKeyTrustNewKey => 'Trust the new key';

  @override
  String get keyboardAuthTitle => 'Authentication';

  @override
  String get keyboardRequestFrom => 'Request from';

  @override
  String get keyboardServerMessage => 'Server message';

  @override
  String get keyboardSubmit => 'Submit';

  @override
  String get keyboardCancel => 'Cancel';

  @override
  String get keyboardShowAnswer => 'Show answer';

  @override
  String get keyboardHideAnswer => 'Hide answer';

  @override
  String get credentialTitle => 'Authentication required';

  @override
  String credentialEndpoint(String username, String host, int port) {
    return '$username@$host:$port';
  }

  @override
  String get credentialPasswordField => 'Password';

  @override
  String get credentialKeyFileField => 'Key file';

  @override
  String get credentialKeyFileRequired => 'Choose a key file.';

  @override
  String get credentialPassphraseField => 'Passphrase';

  @override
  String get credentialSaveInVault => 'Save in vault';

  @override
  String get credentialConnect => 'Connect';

  @override
  String get credentialCancel => 'Cancel';

  @override
  String get credentialVaultUnavailable =>
      'Saved secrets are unavailable. Unlock or restore your system credential store, then retry — or enter the secret below.';

  @override
  String get credentialKeyFileUnreadable =>
      'The file could not be read as text.';

  @override
  String credentialKeyFileReadError(String error) {
    return 'Could not read the key file: $error';
  }

  @override
  String get connectionStateConnecting => 'Connecting…';

  @override
  String get connectionStateReconnecting => 'Reconnecting…';

  @override
  String get connectionFailedTitle => 'Connection failed';

  @override
  String get connectionBlockedTitle => 'Connection blocked';

  @override
  String get connectionDisconnectedTitle => 'Disconnected';

  @override
  String get connectionLogTitle => 'Connection log';

  @override
  String get connectionLogCopy => 'Copy';

  @override
  String get connectionLogEmpty => '(no log captured)';

  @override
  String get connectionRetry => 'Retry';

  @override
  String get vaultSaveFailed =>
      'Could not save the secret to the vault. The connection will continue.';

  @override
  String get sshImportTitle => 'Import servers from ssh config';

  @override
  String get sshImportLoading => 'Reading ssh config…';

  @override
  String sshImportLoadFailed(String path) {
    return 'Could not read $path.';
  }

  @override
  String get sshImportRetry => 'Try Again';

  @override
  String sshImportEmpty(String path) {
    return 'No importable hosts were found in $path.';
  }

  @override
  String get sshImportColumnImport => 'Import';

  @override
  String get sshImportColumnHost => 'Host';

  @override
  String get sshImportColumnEndpoint => 'Endpoint';

  @override
  String get sshImportColumnUser => 'User';

  @override
  String get sshImportColumnAuth => 'Auth';

  @override
  String get sshImportColumnNotes => 'Notes';

  @override
  String get sshImportAuthAgent => 'ssh-agent';

  @override
  String sshImportAuthKey(String path) {
    return 'Key: $path';
  }

  @override
  String sshImportDuplicateExisting(String label) {
    return 'Duplicate of bookmark “$label”';
  }

  @override
  String sshImportDuplicateEarlier(String alias) {
    return 'Duplicate of “$alias” in this import';
  }

  @override
  String get sshImportLimitProxyJump =>
      'Won’t behave as in ssh: ProxyJump — connects directly, not through the jump host';

  @override
  String get sshImportLimitProxyCommand =>
      'Won’t behave as in ssh: ProxyCommand — never executed';

  @override
  String get sshImportLimitMatch =>
      'Won’t behave as in ssh: Match blocks are ignored; settings may differ';

  @override
  String get sshImportLimitHostInclude =>
      'Won’t behave as in ssh: Include inside this host block is not applied';

  @override
  String get sshImportLimitInvalidPort => 'Cannot import: port outside 1–65535';

  @override
  String get sshImportLimitWildcardDefaults =>
      'Won’t behave as in ssh: defaults from a top-level or Host * block are not inherited';

  @override
  String get sshImportUnresolvedIncludes => 'Unresolved includes';

  @override
  String sshImportNoteCycle(String path) {
    return '$path: include loop skipped';
  }

  @override
  String sshImportNoteDepth(String path) {
    return '$path: nested beyond the depth limit';
  }

  @override
  String sshImportNoteUnreadable(String path) {
    return '$path: could not be read';
  }

  @override
  String get sshImportCancel => 'Cancel';

  @override
  String get sshImportAction => 'Import';

  @override
  String sshImportActionCount(int count) {
    return 'Import $count';
  }

  @override
  String sshImportRowSemantics(String alias) {
    return 'Import $alias';
  }

  @override
  String get sshImportCommandLabel => 'Import from ssh config…';

  @override
  String sshImportImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Imported $count favorites',
      one: 'Imported 1 favorite',
    );
    return '$_temp0';
  }

  @override
  String get sshImportFavoritesLoadFailed =>
      'Could not read the favorites file.';

  @override
  String get sshImportFavoritesSaveFailed =>
      'Could not save the imported favorites.';

  @override
  String get bookmarkImportCommandLabel => 'Import from another app…';

  @override
  String get bookmarkImportChooserTitle => 'Import from another app';

  @override
  String get bookmarkImportFileZilla => 'FileZilla';

  @override
  String get bookmarkImportWinScp => 'WinSCP';

  @override
  String get bookmarkImportCyberduck => 'Cyberduck';

  @override
  String bookmarkImportTitle(String source) {
    return 'Import from $source';
  }

  @override
  String bookmarkImportFilesSelected(String source, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$source · $_temp0';
  }

  @override
  String get bookmarkImportEmpty => 'No servers were found in the selection.';

  @override
  String get bookmarkImportReadFailed =>
      'Could not read the selected bookmark file.';

  @override
  String get bookmarkImportPickFailed => 'Could not read the selected file.';

  @override
  String get bookmarkImportChooseAnother => 'Choose another file…';

  @override
  String bookmarkImportStartFolder(String path) {
    return 'Start folder: $path';
  }

  @override
  String bookmarkImportSourceFile(String name) {
    return 'Source: $name';
  }

  @override
  String bookmarkImportTooManyFiles(int max) {
    return 'Select no more than $max files.';
  }

  @override
  String bookmarkImportFileTooLarge(String name, int maxMiB) {
    return '$name is larger than $maxMiB MiB.';
  }

  @override
  String bookmarkImportTotalSizeExceeded(int maxMiB) {
    return 'Selected files exceed $maxMiB MiB in total.';
  }

  @override
  String bookmarkImportInvalidEncoding(String name) {
    return '$name is not valid UTF-8 or UTF-16 text.';
  }

  @override
  String bookmarkImportUnsafeXml(String name) {
    return '$name contains unsafe XML declarations.';
  }

  @override
  String bookmarkImportMalformedSource(String name) {
    return 'Could not parse $name.';
  }

  @override
  String bookmarkImportTooManyRows(int max) {
    return 'The export contains more than $max bookmarks.';
  }

  @override
  String get bookmarkImportAuthPassword => 'Password prompt';

  @override
  String bookmarkImportUnsupportedProtocol(String protocol) {
    return 'Cannot import: $protocol is not SFTP';
  }

  @override
  String get bookmarkImportUnknownProtocol =>
      'Cannot import: protocol is unknown';

  @override
  String get bookmarkImportMissingHost =>
      'Cannot import: host is missing or invalid';

  @override
  String get bookmarkImportCredentialsNotImported =>
      'Saved password is not imported; Poltergeist will ask';

  @override
  String get bookmarkImportUnsupportedKeyFormat =>
      'Cannot import: choose an OpenSSH private key instead';

  @override
  String get bookmarkImportRouteNotImported =>
      'Proxy or tunnel is not imported; connects directly';

  @override
  String get bookmarkImportInvalidRemotePath =>
      'Start folder is invalid; opens the server home instead';

  @override
  String get bookmarkImportFieldTooLong =>
      'Cannot import: one or more fields are too long';

  @override
  String get bookmarkImportInvalidFieldValue =>
      'Cannot import: a field contains control characters';

  @override
  String get bookmarkImportPersistedOutputLimitExceeded =>
      'Cannot import: saved data limit reached';

  @override
  String get probeStatusUnknown => 'Reachability unknown';

  @override
  String get probeStatusOnline => 'Reachable';

  @override
  String get probeStatusOffline => 'Unreachable';

  @override
  String get connectionStateConnected => 'Connected';

  @override
  String get connectionStateNotConnected => 'Not connected';

  @override
  String get connectionsLoading => 'Loading servers';

  @override
  String get connectionsLoadFailed => 'Could not read the favorites file.';

  @override
  String get connectionsBlockedWarning =>
      'Blocked until you review the host key at the next connection attempt.';

  @override
  String get connectionsReviewHostKey => 'Review host key…';

  @override
  String connectionsPaneFailure(String pane, String message) {
    return 'Pane $pane failed: $message';
  }

  @override
  String get sidebarConnectionsSection => 'Connections';

  @override
  String get sidebarUngroupedSection => 'Favorites';

  @override
  String get sidebarEmptyFavorites =>
      'No favorites yet. Save a location as a favorite to see it here.';

  @override
  String get sidebarOpen => 'Open';

  @override
  String get sidebarOpenInNewTab => 'Open in New Tab';

  @override
  String get sidebarOpenInOtherPane => 'Open in Other Pane';

  @override
  String get sidebarRename => 'Rename…';

  @override
  String get sidebarRenameTitle => 'Rename Favorite';

  @override
  String get sidebarRenameFieldLabel => 'Name';

  @override
  String get sidebarMoveToGroup => 'Move to Group';

  @override
  String get sidebarNoGroup => 'No Group';

  @override
  String get sidebarNewGroup => 'New Group…';

  @override
  String get sidebarNewGroupTitle => 'New Group';

  @override
  String get sidebarGroupFieldLabel => 'Group name';

  @override
  String get sidebarDelete => 'Delete';

  @override
  String get sidebarDeleteTitle => 'Delete Favorite';

  @override
  String sidebarDeleteBody(String label) {
    return 'Delete \"$label\" from favorites? This cannot be undone.';
  }

  @override
  String get sidebarActionFailed =>
      'That change couldn\'t be saved. Try again.';

  @override
  String get sidebarDisconnect => 'Disconnect';

  @override
  String get sidebarKindWorkspace => 'Workspace';

  @override
  String get sidebarKindSavedSync => 'Saved sync';

  @override
  String get sidebarWorkspaceUpdate => 'Update Workspace';

  @override
  String get sidebarSyncLater =>
      'Opening saved-sync favorites isn\'t available yet — the sync preview arrives in a later milestone.';

  @override
  String get viewToggleSidebarLabel => 'Show/Hide Sidebar';

  @override
  String get paneOpeningHome => 'Opening home…';

  @override
  String paneConnectingTo(String label) {
    return 'Connecting to $label…';
  }

  @override
  String get paneEmptyFolder => 'This folder is empty.';

  @override
  String get paneDropHintLocal => 'Drop files here to copy them';

  @override
  String get paneDropHintRemote => 'Drop files here to upload them';

  @override
  String dropMoveTo(String dir) {
    return 'Move to $dir';
  }

  @override
  String dropCopyTo(String dir) {
    return 'Copy to $dir';
  }

  @override
  String dropUploadTo(String dir) {
    return 'Upload to $dir';
  }

  @override
  String dropDownloadTo(String dir) {
    return 'Download to $dir';
  }

  @override
  String dropItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String paneItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String paneLoadingFolder(String name) {
    return 'Loading $name — Esc cancels';
  }

  @override
  String get paneCancelLoading => 'Cancel loading';

  @override
  String get paneConnectCancel => 'Cancel';

  @override
  String paneTypeAheadBadge(String buffer) {
    return 'Names starting with \"$buffer\"';
  }

  @override
  String get paneErrorNotFound => 'The folder could not be found.';

  @override
  String get paneErrorPermissionDenied =>
      'You don\'t have permission to open this folder.';

  @override
  String get paneErrorUnsupported => 'This operation is not supported here.';

  @override
  String get paneErrorDisconnected => 'The connection was closed.';

  @override
  String get paneErrorConflict => 'The item changed while being opened.';

  @override
  String get paneErrorCancelled => 'The operation was cancelled.';

  @override
  String get paneErrorOther => 'The folder could not be opened.';

  @override
  String get paneErrorCancel => 'Cancel';

  @override
  String get paneFaultConnectionOpen =>
      'The connection to this server could not be opened.';

  @override
  String get paneFaultLocalOpen =>
      'The local file browser could not be opened.';

  @override
  String get paneFaultListFolder => 'This folder could not be listed.';

  @override
  String get paneFaultInvalidPath =>
      'That is not a folder path this pane can open. Use an absolute path, ~, or a name in this folder.';

  @override
  String get paneFaultRenameNameEmpty => 'Enter a name.';

  @override
  String get paneFaultRenameNameSeparator => 'A name cannot contain “/”.';

  @override
  String get paneFaultRenameNameInvalid => 'That name is not allowed here.';

  @override
  String get paneFaultRenameTargetGone =>
      'The item is no longer in this folder.';

  @override
  String get paneFaultOpenFile => 'The file could not be opened.';

  @override
  String paneConnectionLost(String label) {
    return 'Connection to $label lost — reconnecting…';
  }

  @override
  String paneConnectionRecoveryFailed(String label) {
    return 'Connection to $label could not be restored.';
  }

  @override
  String get paneConnectionLostCancel => 'Cancel';

  @override
  String paneRestoredOffline(String label) {
    return 'Session restored — $label is offline.';
  }

  @override
  String get paneReconnect => 'Reconnect';

  @override
  String get paneNoticeOpenRemoteUnavailable =>
      'Remote files can\'t be opened in place yet — Poltergeist will download and open them in a later milestone.';

  @override
  String get paneNoticeEditLater =>
      'Editing files in Poltergeist isn\'t available yet — the editor arrives in a later milestone.';

  @override
  String get paneNoticeTransferNeedsOtherPane =>
      'To transfer files, show the other pane and open a folder in it.';

  @override
  String get paneNoticeTransferUnavailable =>
      'This file can\'t be transferred to the other pane.';

  @override
  String get paneNoticeDragOutRemote =>
      'Remote items can\'t be dragged out of Poltergeist here yet. Use Download To… instead.';

  @override
  String paneNoticeDragOutLinksLeftOut(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count links were left out: links can\'t be dragged out of Poltergeist.',
      one: '1 link was left out: links can\'t be dragged out of Poltergeist.',
    );
    return '$_temp0';
  }

  @override
  String paneNoticeDragOutNamesLeftOut(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count items were left out: their names aren\'t valid UTF-8, so they can\'t be dragged out.',
      one:
          '1 item was left out: its name isn\'t valid UTF-8, so it can\'t be dragged out.',
    );
    return '$_temp0';
  }

  @override
  String paneNoticeDragOutItemsLeftOut(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count items were left out: links and names that aren\'t valid UTF-8 can\'t be dragged out of Poltergeist.',
      one: '1 item was left out: it can\'t be dragged out of Poltergeist.',
    );
    return '$_temp0';
  }

  @override
  String get paneNoticeDismiss => 'Dismiss';

  @override
  String paneDateToday(String time) {
    return 'Today at $time';
  }

  @override
  String paneDateYesterday(String time) {
    return 'Yesterday at $time';
  }

  @override
  String paneRowSemantics(
    String name,
    String kind,
    String size,
    String modified,
  ) {
    return '$name, $kind, $size, $modified';
  }

  @override
  String paneRowSemanticsFlagged(
    String name,
    String kind,
    String size,
    String modified,
  ) {
    return '$name, $kind, $size, $modified — name not valid UTF-8';
  }

  @override
  String get paneFlaggedNameTooltip =>
      'Name is not valid UTF-8 — shown approximately';

  @override
  String get paneRowKindFile => 'file';

  @override
  String get paneRowKindDirectory => 'folder';

  @override
  String get paneRowKindSymbolicLink => 'symbolic link';

  @override
  String get paneRowKindOther => 'item';

  @override
  String get goBackLabel => 'Back';

  @override
  String get goEditPathLabel => 'Edit Path';

  @override
  String get goEnclosingLabel => 'Enclosing Folder';

  @override
  String get goForwardLabel => 'Forward';

  @override
  String get goOpenLabel => 'Open';

  @override
  String get fileRenameLabel => 'Rename';

  @override
  String get fileGetInfoLabel => 'Get Info';

  @override
  String get paneRenameFieldLabel => 'Rename';

  @override
  String get goToFolderLabel => 'Go to Folder…';

  @override
  String get viewRefreshLabel => 'Refresh';

  @override
  String get paneFocusLeftLabel => 'Focus Left Pane';

  @override
  String get paneFocusRightLabel => 'Focus Right Pane';

  @override
  String get paneSwapFocusLabel => 'Swap Pane Focus';

  @override
  String get editUndoSelectionLabel => 'Undo Selection';

  @override
  String get editRedoSelectionLabel => 'Redo Selection';

  @override
  String get commandDisabledNoSelectionUndo =>
      'No previous selection to restore in this file list';

  @override
  String get commandDisabledNoSelectionRedo =>
      'No selection change to redo in this file list';

  @override
  String get editSelectAllLabel => 'Select All';

  @override
  String get editInvertSelectionLabel => 'Invert Selection';

  @override
  String get selectionQuickSelectLabel => 'Quick Select';

  @override
  String get quickSelectFieldLabel => 'Quick Select';

  @override
  String get quickSelectFieldHint => 'name fragment or *.ext';

  @override
  String get quickSelectAddLabel => 'Add';

  @override
  String get quickSelectRemoveLabel => 'Remove';

  @override
  String get viewFilterLabel => 'Filter';

  @override
  String get paneFilterFieldLabel => 'Filter';

  @override
  String get paneFilterFieldHint => 'name contains';

  @override
  String paneFilterCount(int visible, int total) {
    return '$visible of $total';
  }

  @override
  String get paneFilterClear => 'Clear';

  @override
  String paneFilterNoMatch(String query) {
    return 'No items match \"$query\"';
  }

  @override
  String get panePathFieldLabel => 'Path';

  @override
  String get panePathFieldHint => '/path, ~, or a name in this folder';

  @override
  String get tabStripLabel => 'Tabs';

  @override
  String get windowNewLabel => 'New Window';

  @override
  String get windowCloseLabel => 'Close Window';

  @override
  String get tabNewLabel => 'New Tab';

  @override
  String get tabCloseLabel => 'Close Tab';

  @override
  String get tabReopenClosedLabel => 'Reopen Closed Tab';

  @override
  String get tabNextLabel => 'Next Tab';

  @override
  String get tabPreviousLabel => 'Previous Tab';

  @override
  String get tabLauncherTitle => 'Launcher';

  @override
  String tabTooltipRemote(String server, String path) {
    return '$server — $path';
  }

  @override
  String get tabCloseConfirmTitle => 'Close Tab?';

  @override
  String tabCloseConfirmBody(String tab) {
    return '\"$tab\" has work in progress:';
  }

  @override
  String get tabCloseTriggerNavigation => 'A navigation is still in flight.';

  @override
  String get tabCloseTriggerInlineRename => 'An inline rename is in progress.';

  @override
  String get tabCloseTriggerFolderSize =>
      'A folder-size computation is running.';

  @override
  String get tabCloseTriggerApplyToEnclosed =>
      'An apply-to-enclosed-items change is running.';

  @override
  String get tabCloseTriggerSyncAnchor => 'The tab anchors a sync pair.';

  @override
  String get tabCloseConfirmCancel => 'Cancel';

  @override
  String get tabCloseConfirmClose => 'Close';

  @override
  String get viewToggleSecondPaneLabel => 'Show/Hide Second Pane';

  @override
  String get viewToggleSyncBrowsingLabel => 'Sync Browsing';

  @override
  String get syncBrowsingChip => 'Sync browsing';

  @override
  String get syncBrowsingSuspended => 'Sync browsing suspended';

  @override
  String syncBrowsingSuspendedMissing(String name, String side) {
    return 'Sync browsing suspended — \"$name\" missing on $side';
  }

  @override
  String get syncBrowsingSuspendedOutside =>
      'Sync browsing suspended — outside the anchor subtree';

  @override
  String get syncBrowsingSideLeft => 'left';

  @override
  String get syncBrowsingSideRight => 'right';

  @override
  String get quickConnectTitle => 'Quick Connect';

  @override
  String get quickConnectAddressLabel => 'Server address';

  @override
  String get quickConnectAddressHint =>
      'user@host:port or sftp://user@host/path';

  @override
  String get quickConnectConnect => 'Connect';

  @override
  String quickConnectHintPort(String port, String host) {
    return '$port → port; use sftp://$host/$port for a folder named $port';
  }

  @override
  String quickConnectHintPath(String token) {
    return '$token is out of the port range, so it connects on port 22 and opens a folder named $token.';
  }

  @override
  String get quickConnectHintIpv6 =>
      'The host holds more than one colon. Wrap the IPv6 address in [ ], for example user@[2001:db8::1].';

  @override
  String get quickConnectPasswordStripped =>
      'A pasted password was removed. It is never stored — enter it when prompted.';

  @override
  String get quickConnectEmptyError =>
      'Enter a server address, for example user@host.';

  @override
  String get quickConnectMissingHostError =>
      'Enter a host after the @, for example user@host.';

  @override
  String get quickConnectInvalidPortError =>
      'The port in this address is not valid. Use 1–65535.';

  @override
  String get quickConnectUnsupportedSchemeError =>
      'Only sftp:// addresses are supported here.';

  @override
  String get saveFavoriteNameLabel => 'Name';

  @override
  String get saveFavoriteSave => 'Save';

  @override
  String get saveFavoriteFailed => 'Could not save the favorite. Try again.';

  @override
  String get paneNoticeSaveFavoriteLater =>
      'Saving favorites isn\'t available yet — the sidebar arrives in a later milestone.';

  @override
  String get paneNoticePathCopied => 'Path copied to clipboard.';

  @override
  String get paneNoticeWatchStopped =>
      'This folder stopped updating automatically. Refresh to see new changes.';

  @override
  String paneNoticeExpandFailed(String name, String reason) {
    return 'Couldn\'t show what\'s in “$name”: $reason';
  }

  @override
  String get paneRowExpand => 'Expand';

  @override
  String get paneRowCollapse => 'Collapse';

  @override
  String get infoPanelLabel => 'Info';

  @override
  String get infoPanelClose => 'Close info panel';

  @override
  String get infoPanelEmpty => 'Select an item to inspect it.';

  @override
  String infoPanelSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items selected',
      one: '1 item selected',
    );
    return '$_temp0';
  }

  @override
  String get infoPanelKind => 'Kind';

  @override
  String get infoPanelSize => 'Size';

  @override
  String get infoPanelCalculateSize => 'Calculate';

  @override
  String get infoPanelCancelSize => 'Cancel';

  @override
  String infoPanelSizeProgress(String size, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$size so far — $_temp0';
  }

  @override
  String infoPanelSizeResult(String size, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$size — $_temp0';
  }

  @override
  String infoPanelSizePartial(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items could not be measured',
      one: '1 item could not be measured',
    );
    return '$_temp0';
  }

  @override
  String get infoPanelSizeFailed => 'Could not measure';

  @override
  String get infoPanelModified => 'Modified';

  @override
  String get infoPanelAccessed => 'Accessed';

  @override
  String get infoPanelPermissions => 'Permissions';

  @override
  String infoPanelPermissionsValue(String symbolic, String octal) {
    return '$symbolic ($octal)';
  }

  @override
  String get infoPanelOwner => 'Owner';

  @override
  String get infoPanelGroup => 'Group';

  @override
  String get infoPanelPath => 'Path';

  @override
  String get infoPanelCopyPath => 'Copy path';

  @override
  String get infoPanelPermOctal => 'Octal';

  @override
  String get infoPanelPermInvalid => 'Use four octal digits (0000–7777).';

  @override
  String get infoPanelPermOwner => 'Owner';

  @override
  String get infoPanelPermGroup => 'Group';

  @override
  String get infoPanelPermOthers => 'Others';

  @override
  String get infoPanelPermRead => 'Read';

  @override
  String get infoPanelPermWrite => 'Write';

  @override
  String get infoPanelPermExecute => 'Execute';

  @override
  String infoPanelPermCell(String who, String what) {
    return '$who $what';
  }

  @override
  String get infoPanelPermBlockedName =>
      'The name is not valid UTF-8 — it can\'t be sent to the server.';

  @override
  String get infoPanelPermBlockedLink =>
      'A symbolic link\'s permissions can\'t be changed.';

  @override
  String get infoPanelPermBlockedUnsupported =>
      'This filesystem can\'t change permissions.';

  @override
  String get infoPanelApplyPermissions => 'Apply';

  @override
  String get infoPanelApplyEnclosed => 'Apply to enclosed items…';

  @override
  String get infoPanelPermErrorUnsupported =>
      'This filesystem can\'t change permissions.';

  @override
  String get infoPanelPermErrorDenied =>
      'Permission denied — you may not own this item.';

  @override
  String get infoPanelPermErrorNotFound => 'The item no longer exists.';

  @override
  String get infoPanelPermError => 'The change could not be completed.';

  @override
  String get infoPanelEnclosedTitle => 'Apply to enclosed items?';

  @override
  String infoPanelEnclosedCounting(String name) {
    return 'Counting the items inside “$name”…';
  }

  @override
  String infoPanelEnclosedBody(String octal, String name) {
    return 'Apply $octal to “$name” and the items inside it?';
  }

  @override
  String infoPanelEnclosedBodyCounted(String octal, String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Apply $octal to “$name” and the $count items inside it?',
      one: 'Apply $octal to “$name” and the 1 item inside it?',
      zero: 'Apply $octal to “$name”? It has no changeable items inside.',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedFlaggedCounted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Includes $count items with undecodable names — they will be skipped.',
      one: 'Includes 1 item with an undecodable name — it will be skipped.',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedLinksCounted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Includes $count symbolic links — they will be skipped.',
      one: 'Includes 1 symbolic link — it will be skipped.',
    );
    return '$_temp0';
  }

  @override
  String get infoPanelEnclosedIncomplete =>
      'The count was incomplete — items with undecodable names and symbolic links will be skipped, and some folders could not be read.';

  @override
  String get infoPanelEnclosedCancel => 'Cancel';

  @override
  String get infoPanelEnclosedApply => 'Apply';

  @override
  String infoPanelEnclosedProgress(String octal, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items changed',
      one: '1 item changed',
    );
    return 'Applying $octal… $_temp0';
  }

  @override
  String infoPanelEnclosedDone(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items changed',
      one: '1 item changed',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedCancelled(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items changed',
      one: '1 item changed',
    );
    return 'Cancelled — $_temp0';
  }

  @override
  String get infoPanelEnclosedFailed => 'Could not finish';

  @override
  String infoPanelEnclosedSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items skipped — names not valid UTF-8',
      one: '1 item skipped — name not valid UTF-8',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedLinks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count symbolic links skipped',
      one: '1 symbolic link skipped',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedUnreadable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count folders could not be read',
      one: '1 folder could not be read',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedRefused(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items refused the change',
      one: '1 item refused the change',
    );
    return '$_temp0';
  }

  @override
  String get menuWorkspaces => 'Workspaces';

  @override
  String get workspaceSaveCommand => 'Save Workspace…';

  @override
  String get workspaceSaveTitle => 'Save Workspace';

  @override
  String get workspaceNameField => 'Workspace name';

  @override
  String get workspaceSaveAction => 'Save';

  @override
  String get workspaceSaveCancel => 'Cancel';

  @override
  String workspaceSavedToast(String name) {
    return 'Workspace \"$name\" saved';
  }

  @override
  String workspaceOpenedToast(String name) {
    return 'Workspace \"$name\" opened';
  }

  @override
  String get workspaceUndoAction => 'Undo';

  @override
  String get workspaceMenuEmpty => 'No Saved Workspaces';

  @override
  String get viewToggleActivityPanelLabel => 'Transfers';

  @override
  String get queueTogglePauseLabel => 'Pause/Resume Transfers';

  @override
  String get activityTabActivity => 'Activity';

  @override
  String get activityTabHistory => 'History';

  @override
  String get queuePauseTooltip =>
      'Pause stops new transfers; current files finish';

  @override
  String get queueResumeTooltip => 'Resume the transfer queue';

  @override
  String get activityBandwidthButton => 'Transfer limits';

  @override
  String get activityBandwidthUnlimited => '∞';

  @override
  String get activityClearCompleted => 'Clear completed';

  @override
  String get activityClosePanel => 'Close panel';

  @override
  String get activityEmpty => 'No transfers in progress.';

  @override
  String get activityHistoryEmpty => 'No transfer history yet.';

  @override
  String get activityHistoryFilter => 'Filter history';

  @override
  String get activityHistoryClear => 'Clear History';

  @override
  String activityRestoredBanner(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transfers from your last session are paused',
      one: '1 transfer from your last session is paused',
    );
    return '$_temp0';
  }

  @override
  String get activityRestoredResume => 'Resume';

  @override
  String get activityRestoredDiscard => 'Discard';

  @override
  String get activityCancelTask => 'Cancel';

  @override
  String get activityRetryTask => 'Retry';

  @override
  String get activityRemoveTask => 'Remove';

  @override
  String get activityRevealInPane => 'Reveal in pane';

  @override
  String get activityCopyError => 'Copy error';

  @override
  String get activityHistoryCopy => 'Copy';

  @override
  String get activityTaskRemoteUnavailable =>
      'Remote transfers aren\'t available yet — this build moves local files only.';

  @override
  String get activitySkipItem => 'Skip';

  @override
  String get activityCancelItem => 'Cancel';

  @override
  String get activityExpandTask => 'Show files';

  @override
  String get activityCollapseTask => 'Hide files';

  @override
  String activityConflictsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items need answers',
      one: '1 item needs an answer',
    );
    return '$_temp0';
  }

  @override
  String get conflictResolve => 'Resolve…';

  @override
  String conflictDialogTitle(String name, String destination) {
    return '$name already exists in $destination';
  }

  @override
  String conflictExistingLine(String details) {
    return 'Existing: $details';
  }

  @override
  String conflictReplacingLine(String details) {
    return 'Replacing it with: $details';
  }

  @override
  String get conflictVerbReplace => 'Replace';

  @override
  String get conflictVerbReplaceIfNewer => 'Replace if newer';

  @override
  String get conflictVerbKeepBoth => 'Keep both';

  @override
  String get conflictVerbSkip => 'Skip';

  @override
  String get conflictVerbMerge => 'Merge';

  @override
  String get conflictStop => 'Stop';

  @override
  String get conflictNotNow => 'Not now';

  @override
  String conflictApplyToAll(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count remaining conflicts',
      one: '1 remaining conflict',
    );
    return 'Apply to all $_temp0 in this task';
  }

  @override
  String get quitConfirmTitle => 'Quit while transfers are running?';

  @override
  String get quitConfirmOperationsTitle => 'Quit while operations are running?';

  @override
  String quitConfirmBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transfers are running',
      one: '1 transfer is running',
    );
    return '$_temp0.';
  }

  @override
  String quitConfirmOperationsBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count operations are running',
      one: '1 operation is running',
    );
    return '$_temp0.';
  }

  @override
  String quitConfirmBodyRemaining(int count, String remaining) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transfers are running',
      one: '1 transfer is running',
    );
    return '$_temp0 ($remaining remaining so far).';
  }

  @override
  String quitConfirmOperationsBodyRemaining(int count, String remaining) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count operations are running',
      one: '1 operation is running',
    );
    return '$_temp0 ($remaining remaining so far).';
  }

  @override
  String get quitConfirmRestartNote =>
      'Files in progress restart from the beginning next launch.';

  @override
  String get quitPauseAndQuit => 'Pause and Quit';

  @override
  String get quitCancelTransfersAndQuit => 'Cancel Transfers and Quit';

  @override
  String get quitCancelOperationsAndQuit => 'Cancel Operations and Quit';

  @override
  String get quitKeepTransferring => 'Keep Transferring';

  @override
  String get quitKeepWorking => 'Keep Working';

  @override
  String get quitFlushFailedTitle => 'Transfer state could not be saved';

  @override
  String quitFlushFailedBody(String error) {
    return 'Saving the transfer journal failed: $error. The window stayed open so queued and in-flight transfers are not lost. Quit again to retry, or choose Quit Anyway to close without saving their latest state.';
  }

  @override
  String get quitFlushFailedDismiss => 'Dismiss';

  @override
  String get quitFlushFailedQuitAnyway => 'Quit Anyway';

  @override
  String get transferStateQueued => 'Queued';

  @override
  String get transferStateScanning => 'Scanning…';

  @override
  String get transferStateRunning => 'Running';

  @override
  String get transferStatePaused => 'Paused';

  @override
  String get transferStateCompleted => 'Completed';

  @override
  String get transferStateFailed => 'Failed';

  @override
  String get transferStateCancelled => 'Cancelled';

  @override
  String get transferItemPending => 'Waiting';

  @override
  String get transferItemConflict => 'Needs an answer';

  @override
  String get transferItemSkipped => 'Skipped';

  @override
  String get activityTaskRouteLocal => 'This computer';

  @override
  String activityTaskTitleMulti(int count, String destination) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0 to $destination';
  }

  @override
  String activityTaskTitleDelete(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return 'Delete $_temp0';
  }

  @override
  String get activityDeleteTrashed => 'Moved to trash';

  @override
  String get activityDeletePermanent => 'Deleted permanently';

  @override
  String activityFooterTotals(
    String done,
    String total,
    String bytes,
    String totalBytes,
  ) {
    return '$done of $total items · $bytes of $totalBytes so far';
  }

  @override
  String activityRowSemantics(String label, String state) {
    return '$label, $state';
  }

  @override
  String statusTransferChip(String rate, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tasks',
      one: '$count task',
    );
    return '$rate · $_temp0';
  }

  @override
  String statusLimitChip(String down, String up) {
    return 'Limited: ↓$down ↑$up';
  }

  @override
  String get bandwidthPopoverTitle => 'Transfer limits';

  @override
  String get bandwidthDownLabel => 'Download';

  @override
  String get bandwidthUpLabel => 'Upload';

  @override
  String get bandwidthOff => 'Off';

  @override
  String get bandwidthCustom => 'Custom…';

  @override
  String get bandwidthCustomHint => 'e.g. 2 MB/s';

  @override
  String bandwidthInvalid(String max) {
    return 'Enter a rate like 500 KB/s (up to $max)';
  }

  @override
  String get bandwidthSet => 'Set';

  @override
  String get transferLimitPerServerLabel => 'Simultaneous transfers per server';

  @override
  String get transferLimitAutomatic => 'Automatic';

  @override
  String transferLimitPerServerNote(int total) {
    return 'Automatic lets a server use up to $total at once, the most the app runs in total. Browsing, editing and previews are never held back.';
  }

  @override
  String get historyVerbCopy => 'Copy';

  @override
  String get historyVerbMove => 'Move';

  @override
  String get historyVerbDelete => 'Delete';

  @override
  String get resizeActivityPanel => 'Resize activity panel';

  @override
  String activityPanelHeightPx(int value) {
    return '$value px';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsBackupCommand => 'Back up and sync…';

  @override
  String get settingsCommand => 'Settings…';

  @override
  String get settingsGeneralSection => 'General';

  @override
  String get editorTextSizeSection => 'Built-in editor';

  @override
  String get editorTextSizeLabel => 'Text size';

  @override
  String editorTextSizeValue(int size) {
    return '$size pt';
  }

  @override
  String get editorTextSizeHint =>
      'Zoom In, Zoom Out and Actual Size in an editor change it too.';

  @override
  String get editorZoomInLabel => 'Zoom In';

  @override
  String get editorZoomOutLabel => 'Zoom Out';

  @override
  String get editorActualSizeLabel => 'Actual Size';

  @override
  String get settingsGeneralTab => 'General';

  @override
  String get settingsEditingTab => 'Editing';

  @override
  String get settingsSyncTab => 'Sync';

  @override
  String get settingsAppearanceTab => 'Appearance';

  @override
  String get appearanceThemeSection => 'Theme';

  @override
  String get appearanceThemeHelpTitle => 'Themes';

  @override
  String get appearanceThemeHelp =>
      'A theme is kept on this device only and never syncs. To use one elsewhere, copy it here and paste it into Poltergeist or Séance on the other device.';

  @override
  String get appearancePresetFootnote =>
      'Picking a theme copies its colours here. It is a starting point, not a mode, so everything below stays yours to change.';

  @override
  String appearancePresetTooltip(String name) {
    return 'Use the $name theme';
  }

  @override
  String get appearanceModeSection => 'Mode';

  @override
  String get appearanceModeLabel => 'Automatic colours follow';

  @override
  String get appearanceModeSystem => 'System';

  @override
  String get appearanceModeLight => 'Light';

  @override
  String get appearanceModeDark => 'Dark';

  @override
  String get appearanceModeFixedDark =>
      'This theme has its own surface, so it is always dark. Set Surface to Automatic to choose a mode.';

  @override
  String get appearanceModeFixedLight =>
      'This theme has its own surface, so it is always light. Set Surface to Automatic to choose a mode.';

  @override
  String get appearanceColoursSection => 'Colours';

  @override
  String get appearanceColoursHelpTitle => 'Automatic colours';

  @override
  String get appearanceColoursHelp =>
      'Automatic colours are the light or dark neutrals Poltergeist ships with, as the mode picks them. Once you give the theme a surface of its own, they are mixed from that surface and the text instead. Lines and the selection may be translucent.';

  @override
  String get appearanceSlotAccent => 'Accent';

  @override
  String get appearanceSlotSurface => 'Surface';

  @override
  String get appearanceSlotSidebar => 'Sidebar';

  @override
  String get appearanceSlotRaised => 'Headers and bars';

  @override
  String get appearanceSlotText => 'Text';

  @override
  String get appearanceSlotSecondaryText => 'Secondary text';

  @override
  String get appearanceSlotHairline => 'Lines';

  @override
  String get appearanceSlotSelection => 'Selection';

  @override
  String get appearanceStatusSection => 'Status colours';

  @override
  String get appearanceSlotOnline => 'Connected or online';

  @override
  String get appearanceSlotOffline => 'Failed or offline';

  @override
  String get appearanceSlotConnecting => 'Connecting';

  @override
  String get appearanceSlotUnknown => 'Unknown or idle';

  @override
  String get appearanceStatusFootnote =>
      'Each status also keeps its own shape and its name, so these colours never have to say it alone.';

  @override
  String get appearanceAutomatic => 'Automatic';

  @override
  String appearanceAutomaticSemantics(String label) {
    return '$label: Automatic';
  }

  @override
  String appearanceSwatchTooltip(String label) {
    return 'Choose the $label colour';
  }

  @override
  String appearanceSwatchAutomaticTooltip(String label) {
    return 'Choose a $label colour (now Automatic)';
  }

  @override
  String get appearanceShapeSection => 'Shape and type';

  @override
  String get appearanceFontLabel => 'Interface font';

  @override
  String get appearanceFontHint => 'System default';

  @override
  String get appearanceFontHelper =>
      'The editor and code keep their monospace font.';

  @override
  String get appearanceCorners => 'Corners';

  @override
  String get appearanceCornersSquare => 'Square';

  @override
  String appearanceCornersPercent(int percent) {
    return '$percent%';
  }

  @override
  String appearanceCornersSemantics(String value) {
    return 'Corners $value';
  }

  @override
  String get appearanceShareSection => 'Share';

  @override
  String get appearanceCopy => 'Copy theme';

  @override
  String get appearancePaste => 'Paste theme';

  @override
  String get appearanceShareFootnote =>
      'Copies the theme as text you can keep or send. Pasting reads what it can and leaves everything else at the default.';

  @override
  String get appearanceCopied => 'Theme copied.';

  @override
  String get appearancePasteNotATheme =>
      'The clipboard does not hold a theme. Copy one with Copy theme first.';

  @override
  String get appearanceStartOverSection => 'Start over';

  @override
  String appearanceReset(String name) {
    return 'Reset to $name';
  }

  @override
  String get appearanceResetTitle => 'Reset the theme?';

  @override
  String appearanceResetBody(String name) {
    return 'Every colour, the font and the corners go back to the $name theme. The mode stays as it is.';
  }

  @override
  String get appearanceResetCancel => 'Cancel';

  @override
  String get appearanceResetConfirm => 'Reset';

  @override
  String appearanceUsingPreset(String name) {
    return 'Using $name.';
  }

  @override
  String get appearanceUsingCustom => 'Using your own colours.';

  @override
  String appearanceNotSaved(String error) {
    return 'Appearance not saved: $error';
  }

  @override
  String appearanceHelpTooltip(String title) {
    return 'About $title';
  }

  @override
  String get appearanceHelpClose => 'Close';

  @override
  String get themePresetPoltergeist => 'Poltergeist';

  @override
  String get themePresetGraphite => 'Graphite';

  @override
  String get themePresetPaper => 'Paper';

  @override
  String get themePresetNewsprint => 'Newsprint';

  @override
  String get themePresetSolarized => 'Solarized';

  @override
  String get themePresetMidnight => 'Midnight';

  @override
  String get themePresetTerminal => 'Terminal';

  @override
  String get themePresetVapor => 'Vapor';

  @override
  String get themePresetBubblegum => 'Bubblegum';

  @override
  String get themePresetHighContrast => 'High contrast';

  @override
  String get settingsWindowUnreachable =>
      'Settings could not reach Poltergeist. Close this window and open Settings again.';

  @override
  String get settingsWindowEmpty => 'Nothing to set here yet.';

  @override
  String get settingsFileListsSection => 'File lists';

  @override
  String get foldersOnTopLabel => 'Keep folders on top';

  @override
  String get foldersOnTopSubtitle =>
      'When off, folders sort in among files by the same column.';

  @override
  String get updateCheckEnabledLabel => 'Check for updates';

  @override
  String get updateCheckEnabledSubtitle =>
      'Checks GitHub on launch and only links to the release page — it never downloads anything.';

  @override
  String get backupTitle => 'Bookmark backup';

  @override
  String get backupIntro =>
      'Back up bookmarks, end-to-end encrypted, through a Séance sync server. Nothing readable ever leaves this device.';

  @override
  String get backupModeSeparate =>
      'Separate backup account — a new account just for Poltergeist, on the same server. Works with every Séance version.';

  @override
  String backupModeShared(String version) {
    return 'Shared Séance account — bookmarks live alongside your Séance data, and your Séance servers appear as bookmark sources. This app will hold your Séance encryption passphrase and could read everything in the account, including saved passwords. Requires Séance $version or newer on all devices.';
  }

  @override
  String backupFleetCheckbox(String version) {
    return 'Every device that runs Séance with this account has version $version or newer.';
  }

  @override
  String get backupFleetHelper =>
      'Older Séance versions misread Poltergeist\'s records — update them everywhere before turning this on, and never add an older Séance to this account afterwards: the risk does not end at setup.';

  @override
  String get backupSharedPinDisclosure =>
      'Séance devices accept synced host-key pins without a conflict warning — including pins this app pushes.';

  @override
  String get backupRegistrationClosed =>
      'This server has registration closed. If you run it: temporarily set SEANCE_OPEN_REGISTRATION=1, create the account, then close it again — while it is open, anyone who can reach the server can register, so close it as soon as you are done. If someone else runs it, ask them to create an account for you.';

  @override
  String get backupPassphraseCallout =>
      'The encryption passphrase never leaves your devices and cannot be recovered. Losing it means losing the backup.';

  @override
  String get backupPassphraseCheckFailed =>
      'The encryption passphrase could not decrypt this account\'s records. The passphrase may be wrong, the record may be corrupt, or it may use a newer schema.';

  @override
  String get backupPaused =>
      'Backup paused until the passphrase is verified against the account\'s existing data.';

  @override
  String get backupPausedWayOutShared =>
      'Open Séance on any device signed into this account and add or edit a server, then sync — backup resumes automatically.';

  @override
  String get backupPausedWayOutSeparate =>
      'Open Poltergeist on another device signed into this account and add or edit a bookmark, then sync.';

  @override
  String get backupKdfRefusal =>
      'The sync server returned weaker password-hashing parameters than Poltergeist accepts — refusing to derive your key (possible downgrade attack).';

  @override
  String get backupServerUrlField => 'Sync server URL';

  @override
  String get backupUsernameField => 'Username';

  @override
  String get backupAccountPasswordField => 'Account password';

  @override
  String get backupAccountPasswordHelper =>
      'Authenticates with the sync server.';

  @override
  String get backupEncryptionPassphraseField => 'Encryption passphrase';

  @override
  String get backupEncryptionPassphraseHelper =>
      'Encrypts the backup; use it on every device.';

  @override
  String get backupConfirmPassphraseField => 'Confirm encryption passphrase';

  @override
  String get backupLoginTab => 'Log in';

  @override
  String get backupRegisterTab => 'Register';

  @override
  String get backupContinue => 'Continue';

  @override
  String get backupCancel => 'Cancel';

  @override
  String get backupClose => 'Close';

  @override
  String get backupRegistering => 'Registering…';

  @override
  String get backupLoggingIn => 'Logging in…';

  @override
  String backupEnrollFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get backupValidationUrl => 'Enter a valid HTTP or HTTPS server URL.';

  @override
  String get backupValidationUrlCredentials =>
      'Server URL must not include embedded credentials.';

  @override
  String get backupValidationUsername => 'Enter a username.';

  @override
  String get backupValidationPassword => 'Enter the sync account password.';

  @override
  String get backupValidationPassphrase => 'Enter the encryption passphrase.';

  @override
  String get backupValidationConfirm =>
      'Confirm the encryption passphrase before registering.';

  @override
  String get backupValidationMismatch => 'Encryption passphrases do not match.';

  @override
  String get backupEnrolledModeSeparate => 'Separate backup account';

  @override
  String get backupEnrolledModeShared => 'Shared Séance account';

  @override
  String backupEnrolledSummary(String username, String server) {
    return '$username on $server';
  }

  @override
  String get backupNow => 'Back up now';

  @override
  String get backupSyncing => 'Backing up…';

  @override
  String get backupNeverSynced => 'Not backed up yet.';

  @override
  String get backupLastSyncedJustNow => 'Last backed up just now';

  @override
  String backupLastSyncedMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Last backed up $count min ago',
      one: 'Last backed up 1 min ago',
    );
    return '$_temp0';
  }

  @override
  String backupLastSyncedHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Last backed up $count hours ago',
      one: 'Last backed up 1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String backupLastSyncedDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Last backed up $count days ago',
      one: 'Last backed up 1 day ago',
    );
    return '$_temp0';
  }

  @override
  String backupSyncFailed(String error) {
    return 'Backup failed: $error';
  }

  @override
  String get backupDeadAccount =>
      'The server rejected this device\'s sign-in — the backup account may have been deleted. Bookmarks stay safe on this device and nothing is pushed until you sign in again.';

  @override
  String backupTripwireWarning(String id) {
    return 'A synced record ($id) could not be read after it decrypted — it may have been written by an older Séance version, be corrupt, or use a newer schema. Once the stale device is patched or removed, re-save the affected bookmark to restore it.';
  }

  @override
  String backupPinConflictWarning(String locator) {
    return 'A synced host key for $locator conflicts with the key this device trusts. This can mean a man-in-the-middle attack.';
  }

  @override
  String get backupPinAcceptSynced => 'Use synced key';

  @override
  String get backupSyncSecretsTitle => 'Sync saved passwords & keys';

  @override
  String get backupSyncSecretsSubtitle =>
      'End-to-end encrypted. Only includes servers where credential sync is also on.';

  @override
  String get backupPinKeepLocal => 'Keep local key';

  @override
  String get backupStoreQuarantined =>
      'The local backup record store was unreadable and has been rebuilt — deleted bookmarks may reappear, and pending edits will re-upload on the next backup.';

  @override
  String get backupDeleteAccount => 'Delete backup account…';

  @override
  String get backupDeleteAccountTitle => 'Delete backup account';

  @override
  String backupDeleteAccountBody(String username, String server) {
    return 'This deletes the account $username on $server and every backup stored on it. This cannot be undone.';
  }

  @override
  String backupDeleteConfirmHint(String username) {
    return 'Type $username to confirm.';
  }

  @override
  String get backupDeleteConfirm => 'Delete account';

  @override
  String backupDeleteFailed(String error) {
    return 'Could not delete the account: $error';
  }

  @override
  String get backupSignOut => 'Sign out on this device';

  @override
  String get backupSignOutBody =>
      'This device forgets its sign-in. The account and its data stay on the server.';

  @override
  String get backupSwitchToShared => 'Switch to shared account…';

  @override
  String get backupSwitchTitle => 'Switch to shared account';

  @override
  String get backupSwitchWorking => 'Switching…';

  @override
  String get backupSwitchConflictTitle => 'Resolve host-key conflicts';

  @override
  String backupSwitchConflictBody(String locator) {
    return 'The shared account holds a different host key for $locator. Keeping this device\'s key pushes it to every device on the account — only keep it if you are sure it is the right key.';
  }

  @override
  String get backupSwitchAdoptFleet => 'Use shared key';

  @override
  String get backupSwitchDone =>
      'Switched to the shared account. Bookmarks and host-key pins push on the next backup.';

  @override
  String backupSwitchFailed(String error) {
    return 'The switch could not finish: $error';
  }

  @override
  String get backupDeleteSeparateAfterSwitch =>
      'Also delete the separate backup account…';

  @override
  String backupDeleteSeparateBody(String username, String server) {
    return 'The separate backup account $username on $server still exists — its sign-in was kept while the switch proved out. Delete it now, or keep it.';
  }

  @override
  String get backupDeleteSeparateDecline => 'Keep it';

  @override
  String get backupDeleteSeparateLaterNote =>
      'Removing it later requires re-enrolling into it first.';

  @override
  String get backupDeleteSeparateDone =>
      'The separate backup account was deleted.';

  @override
  String backupDeleteSeparateFailed(String error) {
    return 'Could not delete the separate account: $error';
  }

  @override
  String get fileEditBuiltInLabel => 'Edit in Poltergeist';

  @override
  String get editorDiscardTitle => 'Discard unsaved changes?';

  @override
  String get editorDiscardBody =>
      'Changes not saved to the local copy will be lost.';

  @override
  String get editorDiscardKeep => 'Keep editing';

  @override
  String get editorDiscardConfirm => 'Discard';

  @override
  String get editorFindTooltip => 'Find';

  @override
  String get editorSaveLocallyTooltip => 'Save locally';

  @override
  String get editorSaveAndUploadTooltip => 'Save and upload';

  @override
  String get editorShowReplaceTooltip => 'Find and replace';

  @override
  String get editorReplaceHint => 'Replace with';

  @override
  String get editorReplaceLabel => 'Replace';

  @override
  String get editorReplaceAllLabel => 'Replace all';

  @override
  String get editorFindHint => 'Find in file';

  @override
  String get editorMatchCaseTooltip => 'Match case';

  @override
  String get editorPreviousMatchTooltip => 'Previous match';

  @override
  String get editorNextMatchTooltip => 'Next match';

  @override
  String get editorCloseSearchTooltip => 'Close search';

  @override
  String get editorNoMatches => 'No matches';

  @override
  String editorMatchCount(int current, int total) {
    return '$current/$total';
  }

  @override
  String editorMatchCountCapped(int current, int total) {
    return '$current/$total+';
  }

  @override
  String get editorWholeWordsTooltip => 'Whole words';

  @override
  String get editorRegularExpressionTooltip => 'Regular expression';

  @override
  String get editorFindPatternHint => 'Find by regular expression';

  @override
  String editorPatternInvalid(String detail) {
    return 'Invalid pattern: $detail';
  }

  @override
  String get editorPatternTooSlow => 'Pattern took too long to search';

  @override
  String get editorCaseFoldLimited =>
      'This text cannot be compared without case, so matching was exact.';

  @override
  String get editorGoToLineTooltip => 'Go to line';

  @override
  String get editorCloseGoToLineTooltip => 'Close go to line';

  @override
  String editorGoToLineHint(int lines) {
    return 'Line or line:column, 1 to $lines';
  }

  @override
  String editorGoToLineInvalid(int lines) {
    return 'Enter a line from 1 to $lines, or line:column.';
  }

  @override
  String get editorTextToolsTooltip => 'Text Tools';

  @override
  String get editorLineActions => 'Line actions';

  @override
  String get editorKeepMatchingLines => 'Keep matching';

  @override
  String get editorDeleteMatchingLines => 'Delete matching';

  @override
  String editorLineMatchCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matching lines',
      one: '1 matching line',
    );
    return '$_temp0';
  }

  @override
  String get editorExtractAction => 'Extract';

  @override
  String get editorExtractWholeLinesTooltip => 'Extract whole matching lines';

  @override
  String get editorExtractTemplateHint => 'Template (optional)';

  @override
  String editorExtractCountLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return '$_temp0';
  }

  @override
  String editorExtractCountMatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matches',
      one: '1 match',
    );
    return '$_temp0';
  }

  @override
  String editorReplacementPreviewPlain(String expanded) {
    return '→ $expanded';
  }

  @override
  String editorReplacementPreview(String expanded, String groups) {
    return '→ $expanded  $groups';
  }

  @override
  String get editorReplacementPreviewEmpty => '';

  @override
  String get editorSearchInSelection => 'in selection';

  @override
  String get editorSearchScopeHint =>
      'Only the stored selection is searched — remove to search the file.';

  @override
  String get editorFindInSelection => 'Find in Selection';

  @override
  String get editorSearchHistory => 'Search history';

  @override
  String get editorSearchHistoryEmpty => 'No recent searches this session.';

  @override
  String get editorUseSelectionForFind => 'Use Selection for Find';

  @override
  String get editorFindSelectedText => 'Find Selected Text';

  @override
  String get editorGrepCheatSheet => 'Grep cheat sheet';

  @override
  String get editorGrepCheatSheetTitle => 'Regular expressions';

  @override
  String editorGrepCheatSheetDart(
    String quantifier,
    String bracedRef,
    String namedRef,
  ) {
    return '. any character (except line breaks; (?s) includes them)\n\\d digits  \\w words  \\s whitespace  \\b word edge\n^ start of line  \$ end of line  (?i) ignore case\n(a|b) either  (?:...) group  (?<n>...) named group\na* none+  a+ one+  a? maybe  a$quantifier range (greedy)\n\$1 \$$bracedRef \$$namedRef \$0 in replacements  \$\$ a dollar\nBackslashes stay literal in replacements: \\n is two characters.';
  }

  @override
  String editorGrepCheatSheetBBEdit(String hexRef) {
    return '(?P<n>...) becomes (?<n>...)\n(?>...) becomes (?:...)\na*+ becomes a* (no possessive quantifiers)\n[[:alpha:]] becomes \\w or explicit ranges\n\\A \\z \\Z become ^ \$\n\\x$hexRef becomes \\u$hexRef\n(?x) verbose mode is unsupported\n\\r alone matches CR only; use \\r?\\n for breaks';
  }

  @override
  String get editorTextToolsTitle => 'Text Tools';

  @override
  String get editorTextToolsClose => 'Close text tools';

  @override
  String get editorTextToolsFilterHint => 'Filter tools';

  @override
  String get editorTextToolsNoResults => 'No tools match.';

  @override
  String get editorTextToolsHistoryGroup => 'Repeat and Recent';

  @override
  String get editorCommandsGroup => 'Editing';

  @override
  String get editorCommandDuplicateLine => 'Duplicate Line';

  @override
  String get editorCommandMoveLineUp => 'Move Line Up';

  @override
  String get editorCommandMoveLineDown => 'Move Line Down';

  @override
  String get editorCommandDeleteLine => 'Delete Line';

  @override
  String get editorCommandJoinLines => 'Join Lines';

  @override
  String get editorCommandToggleComment => 'Toggle Comment';

  @override
  String get editorCommandSelectLine => 'Select Line';

  @override
  String get editorCommandSelectParagraph => 'Select Paragraph';

  @override
  String get editorCommandSelectEnclosingBrackets =>
      'Select Enclosing Brackets';

  @override
  String get editorCommandInsertLineAbove => 'Insert Line Above';

  @override
  String get editorCommandInsertLineBelow => 'Insert Line Below';

  @override
  String get editorCommandCopyLine => 'Copy Line';

  @override
  String get editorCommandCutLine => 'Cut Line';

  @override
  String get editorCommandIncrementNumber => 'Increment Number';

  @override
  String get editorCommandDecrementNumber => 'Decrement Number';

  @override
  String get editorCommandPasteMatchIndentation =>
      'Paste and Match Indentation';

  @override
  String get editorCommandGoToMatchingBracket => 'Go to Matching Bracket';

  @override
  String get editorCommandSelectToMatchingBracket =>
      'Select to Matching Bracket';

  @override
  String get editorCommandNextProblem => 'Next Problem';

  @override
  String get editorCommandPreviousProblem => 'Previous Problem';

  @override
  String get editorTextToolGroupLines => 'Lines';

  @override
  String get editorTextToolGroupChangeCase => 'Case';

  @override
  String get editorTextToolGroupWhitespace => 'Whitespace';

  @override
  String get editorTextToolGroupCleanUp => 'Clean Up';

  @override
  String get editorTextToolGroupWrap => 'Wrap';

  @override
  String get editorTextToolGroupEncode => 'Encode';

  @override
  String get editorTextToolGroupInsert => 'Insert';

  @override
  String get editorTextToolNameSortLines => 'Sort Lines';

  @override
  String get editorTextToolNameReverseLines => 'Reverse Lines';

  @override
  String get editorTextToolNameShuffleLines => 'Shuffle Lines';

  @override
  String get editorTextToolNameRemoveDuplicateLines => 'Remove Duplicate Lines';

  @override
  String get editorTextToolNameRemoveBlankLines => 'Remove Blank Lines';

  @override
  String get editorTextToolNameCollapseBlankLines => 'Collapse Blank Lines';

  @override
  String get editorTextToolNameUppercase => 'UPPERCASE';

  @override
  String get editorTextToolNameLowercase => 'lowercase';

  @override
  String get editorTextToolNameTitleCase => 'Title Case';

  @override
  String get editorTextToolNameSentenceCase => 'Sentence case';

  @override
  String get editorTextToolNameCamelCase => 'camelCase';

  @override
  String get editorTextToolNamePascalCase => 'PascalCase';

  @override
  String get editorTextToolNameSnakeCase => 'snake_case';

  @override
  String get editorTextToolNameKebabCase => 'kebab-case';

  @override
  String get editorTextToolNameConstantCase => 'CONSTANT_CASE';

  @override
  String get editorTextToolNameTrimTrailingWhitespace =>
      'Trim Trailing Whitespace';

  @override
  String get editorTextToolNameTrimLeadingWhitespace =>
      'Trim Leading Whitespace';

  @override
  String get editorTextToolNameNormalizeSpaces => 'Normalize Spaces';

  @override
  String get editorTextToolNameNormalizeLineEndings => 'Normalize Line Endings';

  @override
  String get editorTextToolNameConvertIndentationToSpaces =>
      'Convert Indentation to Spaces';

  @override
  String get editorTextToolNameConvertIndentationToTabs =>
      'Convert Indentation to Tabs';

  @override
  String get editorTextToolNameConvertTabsToSpaces => 'Convert Tabs to Spaces';

  @override
  String get editorTextToolNameHardWrap => 'Hard Wrap';

  @override
  String get editorTextToolNameStraightenQuotes => 'Straighten Quotes';

  @override
  String get editorTextToolNameZapGremlins => 'Zap Gremlins';

  @override
  String get editorTextToolNameRemoveAnsiEscapes => 'Remove ANSI Escapes';

  @override
  String get editorTextToolNameConvertToAscii => 'Convert to ASCII';

  @override
  String get editorTextToolNameStripDiacritics => 'Strip Diacritics';

  @override
  String get editorTextToolNameComposeAccents => 'Compose Accents';

  @override
  String get editorTextToolNameDecomposeAccents => 'Decompose Accents';

  @override
  String get editorTextToolNamePrefixSuffixLines => 'Prefix/Suffix Lines';

  @override
  String get editorTextToolNameNumberLines => 'Number Lines';

  @override
  String get editorTextToolNameUnwrapParagraphs => 'Unwrap Paragraphs';

  @override
  String get editorTextToolNameJoinLinesWith => 'Join Lines With';

  @override
  String get editorTextToolNameUrlEncode => 'URL Encode';

  @override
  String get editorTextToolNameUrlDecode => 'URL Decode';

  @override
  String get editorTextToolNameBase64Encode => 'Base64 Encode';

  @override
  String get editorTextToolNameBase64Decode => 'Base64 Decode';

  @override
  String get editorTextToolNameHtmlEntityEncode => 'Encode HTML Entities';

  @override
  String get editorTextToolNameHtmlEntityDecode => 'Decode HTML Entities';

  @override
  String get editorTextToolNameEscapeJsonString => 'Escape as JSON String';

  @override
  String get editorTextToolNameUnescapeBackslashSequences =>
      'Unescape Backslash Sequences';

  @override
  String get editorTextToolNameFormatJson => 'Format JSON';

  @override
  String get editorTextToolNameMinifyJson => 'Minify JSON';

  @override
  String get editorTextToolNameInsertDate => 'Date';

  @override
  String get editorTextToolNameInsertDateTime => 'Date and Time';

  @override
  String get editorTextToolNameInsertUtcTimestamp => 'UTC Timestamp';

  @override
  String get editorTextToolNameInsertUuid => 'UUID';

  @override
  String get editorTextToolNameKeepLinesMatching => 'Keep Lines Matching';

  @override
  String get editorTextToolNameDeleteLinesMatching => 'Delete Lines Matching';

  @override
  String get editorTextToolNameExtractMatches => 'Extract Matches';

  @override
  String get editorTextToolDescriptionSortLines =>
      'Orders lines alphabetically.';

  @override
  String get editorTextToolDescriptionReverseLines =>
      'Reverses the order of lines.';

  @override
  String get editorTextToolDescriptionShuffleLines =>
      'Puts lines in a random order.';

  @override
  String get editorTextToolDescriptionRemoveDuplicateLines =>
      'Deletes repeated lines, keeping the first of each.';

  @override
  String get editorTextToolDescriptionRemoveBlankLines =>
      'Deletes empty and whitespace-only lines.';

  @override
  String get editorTextToolDescriptionCollapseBlankLines =>
      'Collapses runs of blank lines to a single blank line.';

  @override
  String get editorTextToolDescriptionUppercase =>
      'Changes the word or selection to UPPERCASE.';

  @override
  String get editorTextToolDescriptionLowercase =>
      'Changes the word or selection to lowercase.';

  @override
  String get editorTextToolDescriptionTitleCase =>
      'Changes the word or selection to Title Case.';

  @override
  String get editorTextToolDescriptionSentenceCase =>
      'Changes the word or selection to Sentence case.';

  @override
  String get editorTextToolDescriptionCamelCase =>
      'Changes the word or selection to camelCase.';

  @override
  String get editorTextToolDescriptionPascalCase =>
      'Changes the word or selection to PascalCase.';

  @override
  String get editorTextToolDescriptionSnakeCase =>
      'Changes the word or selection to snake_case.';

  @override
  String get editorTextToolDescriptionKebabCase =>
      'Changes the word or selection to kebab-case.';

  @override
  String get editorTextToolDescriptionConstantCase =>
      'Changes the word or selection to CONSTANT_CASE.';

  @override
  String get editorTextToolDescriptionTrimTrailingWhitespace =>
      'Removes spaces and tabs from the ends of lines.';

  @override
  String get editorTextToolDescriptionTrimLeadingWhitespace =>
      'Removes spaces and tabs from the starts of lines.';

  @override
  String get editorTextToolDescriptionNormalizeSpaces =>
      'Replaces no-break and other Unicode spaces with plain spaces.';

  @override
  String get editorTextToolDescriptionNormalizeLineEndings =>
      'Makes all line breaks follow the buffer convention.';

  @override
  String get editorTextToolDescriptionConvertIndentationToSpaces =>
      'Replaces leading tabs with spaces, then indents with spaces.';

  @override
  String get editorTextToolDescriptionConvertIndentationToTabs =>
      'Replaces leading space runs with tabs, then indents with tabs.';

  @override
  String get editorTextToolDescriptionConvertTabsToSpaces =>
      'Expands all tabs to text-column stops. The width starts from the document setting.';

  @override
  String get editorTextToolDescriptionHardWrap =>
      'Wraps words to text columns, keeping quote/comment prefixes and leaving lists intact.';

  @override
  String get editorTextToolDescriptionStraightenQuotes =>
      'Replaces curly quotes with straight ASCII quotes.';

  @override
  String get editorTextToolDescriptionZapGremlins =>
      'Removes or replaces characters that do not belong in text.';

  @override
  String get editorTextToolDescriptionRemoveAnsiEscapes =>
      'Strips terminal colors and escape sequences.';

  @override
  String get editorTextToolDescriptionConvertToAscii =>
      'Replaces quotes, dashes and accented Latin with ASCII look-alikes.';

  @override
  String get editorTextToolDescriptionStripDiacritics =>
      'Removes combining marks, leaving the base letters.';

  @override
  String get editorTextToolDescriptionComposeAccents =>
      'Composes accented characters into their composed form.';

  @override
  String get editorTextToolDescriptionDecomposeAccents =>
      'Decomposes accented characters into base plus marks.';

  @override
  String get editorTextToolDescriptionPrefixSuffixLines =>
      'Adds or removes the same text at the start or end of each line.';

  @override
  String get editorTextToolDescriptionNumberLines =>
      'Adds or removes line numbers.';

  @override
  String get editorTextToolDescriptionRemoveAnsiEscapes2 =>
      'Strips terminal colors and escape sequences.';

  @override
  String get editorTextToolDescriptionUnwrapParagraphs =>
      'Joins each paragraph into a single line.';

  @override
  String get editorTextToolDescriptionJoinLinesWith =>
      'Joins the selected lines with a separator.';

  @override
  String get editorTextToolDescriptionUrlEncode =>
      'Percent-encodes the selection for a URL.';

  @override
  String get editorTextToolDescriptionUrlDecode =>
      'Decodes percent-encoded text.';

  @override
  String get editorTextToolDescriptionBase64Encode =>
      'Encodes the selection as Base64.';

  @override
  String get editorTextToolDescriptionBase64Decode => 'Decodes Base64 text.';

  @override
  String get editorTextToolDescriptionHtmlEntityEncode =>
      'Escapes HTML specials and non-ASCII as entities.';

  @override
  String get editorTextToolDescriptionHtmlEntityDecode =>
      'Decodes named and numeric HTML entities.';

  @override
  String get editorTextToolDescriptionEscapeJsonString =>
      'Escapes the selection as a JSON string body.';

  @override
  String get editorTextToolDescriptionUnescapeBackslashSequences =>
      'Decodes backslash escapes such as \\n and \\uXXXX.';

  @override
  String get editorTextToolDescriptionFormatJson =>
      'Pretty-prints JSON with two-space indent, keeping values verbatim.';

  @override
  String get editorTextToolDescriptionMinifyJson =>
      'Removes insignificant whitespace from JSON, keeping values verbatim.';

  @override
  String get editorTextToolDescriptionInsertDate =>
      'Inserts the current date as YYYY-MM-DD.';

  @override
  String get editorTextToolDescriptionInsertDateTime =>
      'Inserts the local date and time as YYYY-MM-DDThh:mm:ss.';

  @override
  String get editorTextToolDescriptionInsertUtcTimestamp =>
      'Inserts the UTC timestamp as YYYY-MM-DDThh:mm:ssZ.';

  @override
  String get editorTextToolDescriptionInsertUuid => 'Inserts a random UUID.';

  @override
  String get editorTextToolDescriptionKeepLinesMatching =>
      'Deletes every line that does not match the pattern.';

  @override
  String get editorTextToolDescriptionDeleteLinesMatching =>
      'Deletes every line that matches the pattern.';

  @override
  String get editorTextToolDescriptionExtractMatches =>
      'Collects every match, one per line, where it is sent.';

  @override
  String get editorTextToolKeywordsConvertTabsToSpaces =>
      'detab\nexpand tabs\ntab stops';

  @override
  String get editorTextToolKeywordsHardWrap =>
      'reflow\nfill paragraph\nwrap lines';

  @override
  String get editorTextToolKeywordsNormalizeLineEndings =>
      'eol\ncrlf\nlf\ncarriage return';

  @override
  String get editorTextToolKeywordsSortLines => 'order\nalphabetize\narrange';

  @override
  String get editorTextToolKeywordsReverseLines => 'flip\ninvert order';

  @override
  String get editorTextToolKeywordsShuffleLines => 'randomize\nmix lines';

  @override
  String get editorTextToolKeywordsRemoveDuplicateLines =>
      'dedupe\nuniq\nunique';

  @override
  String get editorTextToolKeywordsRemoveBlankLines =>
      'empty lines\ndelete blanks';

  @override
  String get editorTextToolKeywordsCollapseBlankLines =>
      'squeeze blank lines\nsingle blank\ncollapse empty';

  @override
  String get editorTextToolKeywordsUppercase => 'all caps\ncapitalize\nupcase';

  @override
  String get editorTextToolKeywordsLowercase => 'downcase\nsmall letters';

  @override
  String get editorTextToolKeywordsTitleCase => 'capitalize words\nheadline';

  @override
  String get editorTextToolKeywordsSentenceCase => 'capitalize sentences';

  @override
  String get editorTextToolKeywordsCamelCase => 'lower camel\nidentifier';

  @override
  String get editorTextToolKeywordsPascalCase => 'upper camel\nidentifier';

  @override
  String get editorTextToolKeywordsSnakeCase => 'underscore\nidentifier';

  @override
  String get editorTextToolKeywordsKebabCase => 'hyphen\ndash case\nidentifier';

  @override
  String get editorTextToolKeywordsConstantCase =>
      'screaming snake\nmacro\nidentifier';

  @override
  String get editorTextToolKeywordsTrimTrailingWhitespace =>
      'trailing spaces\nrstrip\nstrip whitespace';

  @override
  String get editorTextToolKeywordsTrimLeadingWhitespace =>
      'leading spaces\nlstrip\nunindent all';

  @override
  String get editorTextToolKeywordsNormalizeSpaces =>
      'non-breaking space\nunicode spaces\nnbsp';

  @override
  String get editorTextToolKeywordsConvertIndentationToSpaces =>
      'tabs to spaces\ndetab';

  @override
  String get editorTextToolKeywordsConvertIndentationToTabs =>
      'spaces to tabs\nentab';

  @override
  String get editorTextToolKeywordsStraightenQuotes =>
      'smart quotes\ntypographic quotes';

  @override
  String get editorTextToolKeywordsZapGremlins =>
      'control characters\ninvisible characters';

  @override
  String get editorTextToolKeywordsConvertToAscii =>
      'ascii\ntransliterate\nlatin\nunaccent';

  @override
  String get editorTextToolKeywordsStripDiacritics =>
      'diacritics\naccents\nremove marks\ncombining';

  @override
  String get editorTextToolKeywordsComposeAccents =>
      'nfc\nprecompose\nunicode normalize\naccents';

  @override
  String get editorTextToolKeywordsDecomposeAccents =>
      'nfd\ndecompose\nunicode normalize\naccents';

  @override
  String get editorTextToolKeywordsPrefixSuffixLines =>
      'quote level\ncomment out\naffix';

  @override
  String get editorTextToolKeywordsNumberLines => 'line numbers\nenumerate';

  @override
  String get editorTextToolKeywordsRemoveAnsiEscapes =>
      'terminal colors\nansi codes\nvt100';

  @override
  String get editorTextToolKeywordsUnwrapParagraphs =>
      'unwrap lines\nreflow\nremove line breaks';

  @override
  String get editorTextToolKeywordsJoinLinesWith => 'join\nunlines\nflatten';

  @override
  String get editorTextToolKeywordsUrlEncode => 'percent encode\nuri encode';

  @override
  String get editorTextToolKeywordsUrlDecode => 'percent decode\nuri decode';

  @override
  String get editorTextToolKeywordsBase64Encode => 'b64\nencode base64';

  @override
  String get editorTextToolKeywordsBase64Decode => 'b64\ndecode base64';

  @override
  String get editorTextToolKeywordsHtmlEntityEncode =>
      'html escape\nentities\nescape html';

  @override
  String get editorTextToolKeywordsHtmlEntityDecode =>
      'html unescape\nentities\nunescape html';

  @override
  String get editorTextToolKeywordsEscapeJsonString =>
      'json escape\nescape string';

  @override
  String get editorTextToolKeywordsUnescapeBackslashSequences =>
      'unescape\nescape sequences\nbackslash';

  @override
  String get editorTextToolKeywordsFormatJson =>
      'pretty print\njson format\nindent json';

  @override
  String get editorTextToolKeywordsMinifyJson =>
      'minify\ncompact json\njson min';

  @override
  String get editorTextToolKeywordsKeepLinesMatching =>
      'process lines matching\nfilter lines\ngrep lines';

  @override
  String get editorTextToolKeywordsDeleteLinesMatching =>
      'process lines matching\nfilter lines\ndelete matching';

  @override
  String get editorTextToolKeywordsExtractMatches =>
      'collect matches\ngrep -o\nsubmatches';

  @override
  String get editorTextToolKeywordsInsertDate => 'today\ncurrent date';

  @override
  String get editorTextToolKeywordsInsertDateTime =>
      'now\ntimestamp\ncurrent time';

  @override
  String get editorTextToolKeywordsInsertUtcTimestamp =>
      'now\nzulu\ngmt\ntimestamp';

  @override
  String get editorTextToolKeywordsInsertUuid => 'guid\nrandom id';

  @override
  String get editorTextToolOptionSortLinesOrder => 'Order';

  @override
  String get editorTextToolOptionSortLinesIgnoreCase => 'Ignore case';

  @override
  String get editorTextToolOptionSortLinesNumbersByValue => 'Numbers by value';

  @override
  String get editorTextToolOptionSortLinesByLength => 'By length';

  @override
  String get editorTextToolOptionSortLinesIgnoreLeadingWhitespace =>
      'Ignore leading whitespace';

  @override
  String get editorTextToolOptionSortLinesKeepFirstLine =>
      'Leave first line in place';

  @override
  String get editorTextToolOptionRemoveDuplicateLinesAdjacentOnly =>
      'Adjacent only';

  @override
  String get editorTextToolOptionRemoveDuplicateLinesIgnoreCase =>
      'Ignore case';

  @override
  String
  get editorTextToolOptionRemoveDuplicateLinesIgnoreSurroundingWhitespace =>
      'Ignore surrounding whitespace';

  @override
  String get editorTextToolOptionRemoveDuplicateLinesKeepBlankLines =>
      'Keep blank lines';

  @override
  String get editorTextToolOptionRemoveDuplicateLinesRemoveEveryCopy =>
      'Remove every copy';

  @override
  String get editorTextToolOptionZapGremlinsControls => 'Control characters';

  @override
  String get editorTextToolOptionZapGremlinsInvisible => 'Invisible characters';

  @override
  String get editorTextToolOptionZapGremlinsBidi => 'Bidirectional controls';

  @override
  String get editorTextToolOptionZapGremlinsDamaged => 'Damaged encoding';

  @override
  String get editorTextToolOptionZapGremlinsNonAscii => 'All non-ASCII';

  @override
  String get editorTextToolOptionZapGremlinsAction => 'Action';

  @override
  String get editorTextToolOptionZapGremlinsCharacter =>
      'Replacement character';

  @override
  String get editorTextToolOptionPrefixSuffixLinesMode => 'Mode';

  @override
  String get editorTextToolOptionPrefixSuffixLinesWhere => 'Where';

  @override
  String get editorTextToolOptionPrefixSuffixLinesText => 'Text';

  @override
  String get editorTextToolOptionPrefixSuffixLinesSkipBlankLines =>
      'Skip blank lines';

  @override
  String get editorTextToolOptionNumberLinesMode => 'Mode';

  @override
  String get editorTextToolOptionNumberLinesStart => 'Start at';

  @override
  String get editorTextToolOptionNumberLinesStep => 'Step by';

  @override
  String get editorTextToolOptionNumberLinesSeparator => 'Separator';

  @override
  String get editorTextToolOptionNumberLinesPadding => 'Padding';

  @override
  String get editorTextToolOptionJoinLinesWithSeparator => 'Separator';

  @override
  String get editorTextToolOptionJoinLinesWithTrim => 'Trim lines';

  @override
  String get editorTextToolOptionJoinLinesWithSkipBlankLines =>
      'Skip blank lines';

  @override
  String get editorTextToolOptionConvertTabsToSpacesWidth => 'Tab width';

  @override
  String get editorTextToolOptionHardWrapWidth => 'Text columns';

  @override
  String get editorTextToolOptionHardWrapFill => 'Fill paragraphs';

  @override
  String get editorTextToolChoiceAscending => 'A to Z';

  @override
  String get editorTextToolChoiceDescending => 'Z to A';

  @override
  String get editorTextToolChoiceInsert => 'Insert';

  @override
  String get editorTextToolChoiceRemove => 'Remove';

  @override
  String get editorTextToolChoiceAdd => 'Add';

  @override
  String get editorTextToolChoicePrefix => 'Prefix';

  @override
  String get editorTextToolChoiceSuffix => 'Suffix';

  @override
  String get editorTextToolChoiceNone => 'None';

  @override
  String get editorTextToolChoiceSpaces => 'Spaces';

  @override
  String get editorTextToolChoiceZeros => 'Zeros';

  @override
  String get editorTextToolChoiceDelete => 'Delete';

  @override
  String get editorTextToolChoiceReplaceWithCharacter =>
      'Replace with character';

  @override
  String get editorTextToolChoiceEntity => 'Numeric entity';

  @override
  String get editorTextToolChoiceInPlace => 'In place';

  @override
  String get editorTextToolChoiceClipboard => 'Clipboard';

  @override
  String get editorTextToolChoiceNewDocument => 'New document';

  @override
  String editorTextToolChoiceEscape(String form) {
    return 'Escape as $form';
  }

  @override
  String editorTextToolDisabledToggle(String option) {
    return 'no $option';
  }

  @override
  String editorTextToolOptionWithValue(String option, int value) {
    return '$option $value';
  }

  @override
  String get editorTextToolRepeatNone => 'Repeat';

  @override
  String editorTextToolRepeat(String name) {
    return 'Repeat $name';
  }

  @override
  String editorTextToolRepeatWithSummary(String name, String summary) {
    return 'Repeat $name ($summary)';
  }

  @override
  String editorTextToolRecentWithSummary(String name, String summary) {
    return '$name ($summary)';
  }

  @override
  String get editorTextToolWhereSelection => 'in the selection';

  @override
  String get editorTextToolWhereDocument => 'in the whole document';

  @override
  String get editorTextToolWhereParagraph => 'in the paragraph';

  @override
  String get editorTextToolWhereWord => 'in the word';

  @override
  String get editorTextToolWhereCaret => 'at the caret';

  @override
  String get editorTextToolRefusalNothingSelected => 'nothing selected';

  @override
  String get editorTextToolRefusalNoWordAtCaret => 'no word at the caret';

  @override
  String get editorTextToolRefusalResultNotText =>
      'the result is binary, not text';

  @override
  String get editorTextToolRefusalTooLarge => 'the result is too large to save';

  @override
  String get editorTextToolRefusalRequiresTabs =>
      'this format requires tab indentation';

  @override
  String get editorTextToolRefusalRequiresNormalizedLineEndings =>
      'use Normalize Line Endings first for lone CR separators';

  @override
  String get editorTextToolRefusalNoPattern => 'no pattern to match';

  @override
  String get editorTextToolRefusalInvalidPattern =>
      'the pattern does not compile';

  @override
  String get editorTextToolRefusalPatternFailed => 'the pattern search failed';

  @override
  String get editorTextToolRefusalUnavailable =>
      'this destination is not available';

  @override
  String get editorTextToolRefusalInvalidJson => 'invalid JSON';

  @override
  String editorTextToolRefusalInvalidJsonAt(String detail) {
    return 'invalid JSON at $detail';
  }

  @override
  String editorTextToolNoticeRefused(String name, String reason) {
    return '$name: not applied, $reason.';
  }

  @override
  String editorTextToolNoticeSentence(String name, String sentence) {
    return '$name: $sentence';
  }

  @override
  String editorTextToolChangedSortLines(int changed, int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'moved $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedReverseLines(int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'reversed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedShuffleLines(int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'shuffled $_temp0 $where.';
  }

  @override
  String editorTextToolChangedRemovedOfScope(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'removed $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedRemoveBlankLines(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed blank lines',
      one: '1 blank line',
    );
    return 'removed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedCollapseBlankLines(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed blank lines',
      one: '1 blank line',
    );
    return 'collapsed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedTrimmedWhitespaceOn(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'trimmed whitespace on $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedNormalizedSpaces(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed spaces',
      one: '1 space',
    );
    return 'normalized $_temp0 $where.';
  }

  @override
  String editorTextToolChangedExpandedTabs(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed tabs',
      one: '1 tab',
    );
    return 'expanded $_temp0 $where.';
  }

  @override
  String editorTextToolChangedHardWrap(int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'wrapped $_temp0 $where.';
  }

  @override
  String editorTextToolChangedNormalizeLineEndings(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope line breaks',
      one: '1 line break',
    );
    return 'normalized $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedChangedCase(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'changed the case of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedConvertedIndentationToSpaces(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'converted indentation to spaces on $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedConvertedIndentationToTabs(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'converted indentation to tabs on $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedUppercased(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'uppercased $_temp0 $where.';
  }

  @override
  String editorTextToolChangedLowercased(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'lowercased $_temp0 $where.';
  }

  @override
  String editorTextToolChangedStraightenedQuotes(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed quotes',
      one: '1 quote',
    );
    return 'straightened $_temp0 $where.';
  }

  @override
  String editorTextToolChangedConvertToAscii(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'converted $_temp0 $where.';
  }

  @override
  String editorTextToolChangedConvertToAsciiWithLeft(
    int changed,
    String where,
    int left,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    String _temp1 = intl.Intl.pluralLogic(
      left,
      locale: localeName,
      other: '$left characters',
      one: '1 character',
    );
    return 'converted $_temp0 $where, $_temp1 without an equivalent left.';
  }

  @override
  String editorTextToolChangedStrippedMarks(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed marks',
      one: '1 mark',
    );
    return 'stripped $_temp0 $where.';
  }

  @override
  String editorTextToolChangedComposed(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'composed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedDecomposed(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'decomposed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedFormatted(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'formatted $_temp0 $where.';
  }

  @override
  String editorTextToolChangedMinified(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'minified $_temp0 $where.';
  }

  @override
  String editorTextToolChangedZapEscaped(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed gremlins',
      one: '1 gremlin',
    );
    return 'escaped $_temp0 $where.';
  }

  @override
  String editorTextToolChangedZapReplaced(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed gremlins',
      one: '1 gremlin',
    );
    return 'replaced $_temp0 $where.';
  }

  @override
  String editorTextToolChangedZapReplacedWithEntities(
    int changed,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed gremlins',
      one: '1 gremlin',
    );
    return 'replaced $_temp0 with entities $where.';
  }

  @override
  String editorTextToolChangedZapRemoved(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed gremlins',
      one: '1 gremlin',
    );
    return 'removed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedRemovedEscapeSequences(
    int changed,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed escape sequences',
      one: '1 escape sequence',
    );
    return 'removed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedUnwrapped(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed line breaks',
      one: '1 line break',
    );
    return 'unwrapped $_temp0 $where.';
  }

  @override
  String editorTextToolChangedChangedOfScope(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'changed $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedJoined(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed lines',
      one: '1 line',
    );
    return 'joined $_temp0 $where.';
  }

  @override
  String editorTextToolChangedEncoded(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'encoded $_temp0 $where.';
  }

  @override
  String editorTextToolChangedDecoded(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'decoded $_temp0 $where.';
  }

  @override
  String editorTextToolChangedEncodedAsEntities(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'encoded $_temp0 as entities $where.';
  }

  @override
  String editorTextToolChangedDecodedEntities(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed entities',
      one: '1 entity',
    );
    return 'decoded $_temp0 $where.';
  }

  @override
  String editorTextToolChangedEscaped(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'escaped $_temp0 $where.';
  }

  @override
  String editorTextToolChangedDecodedEscapes(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed escapes',
      one: '1 escape',
    );
    return 'decoded $_temp0 $where.';
  }

  @override
  String editorTextToolChangedInsertedDate(String where) {
    return 'inserted the current date $where.';
  }

  @override
  String editorTextToolChangedInsertedDateTime(String where) {
    return 'inserted the date and time $where.';
  }

  @override
  String editorTextToolChangedInsertedUtcTimestamp(String where) {
    return 'inserted the UTC timestamp $where.';
  }

  @override
  String editorTextToolChangedInsertedUuid(String where) {
    return 'inserted a UUID $where.';
  }

  @override
  String editorTextToolChangedExtractCopiedLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return 'copied $_temp0 to the clipboard.';
  }

  @override
  String editorTextToolChangedExtractCopiedMatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matches',
      one: '1 match',
    );
    return 'copied $_temp0 to the clipboard.';
  }

  @override
  String editorTextToolChangedExtractOpenedLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return 'opened $_temp0 in a new document.';
  }

  @override
  String editorTextToolChangedExtractOpenedMatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matches',
      one: '1 match',
    );
    return 'opened $_temp0 in a new document.';
  }

  @override
  String editorTextToolChangedExtractedLines(int count, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return 'extracted $_temp0 $where.';
  }

  @override
  String editorTextToolChangedExtractedMatches(int count, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matches',
      one: '1 match',
    );
    return 'extracted $_temp0 $where.';
  }

  @override
  String editorTextToolChangedFallback(int scope, String where) {
    return 'changed $scope units $where.';
  }

  @override
  String editorTextToolUnchangedNoMatches(String where) {
    return 'no matches $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyInOrder(int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'nothing to change, $_temp0 $where already in order.';
  }

  @override
  String editorTextToolUnchangedNothingToChangeScope(int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'nothing to change, $_temp0 $where.';
  }

  @override
  String editorTextToolUnchangedNoDuplicateLines(String where) {
    return 'nothing to change, no duplicate lines $where.';
  }

  @override
  String editorTextToolUnchangedNoBlankLines(String where) {
    return 'nothing to change, no blank lines $where.';
  }

  @override
  String editorTextToolUnchangedNoBlankLineRuns(String where) {
    return 'nothing to change, no blank-line runs $where.';
  }

  @override
  String editorTextToolUnchangedNothingToTrim(String where) {
    return 'nothing to trim $where.';
  }

  @override
  String editorTextToolUnchangedNoUnicodeSpaces(String where) {
    return 'no Unicode spaces $where.';
  }

  @override
  String editorTextToolUnchangedNoTabsToExpand(String where) {
    return 'no tabs to expand $where.';
  }

  @override
  String editorTextToolUnchangedNothingToWrap(String where) {
    return 'nothing to wrap $where.';
  }

  @override
  String editorTextToolUnchangedEndingsConsistent(String where) {
    return 'line endings already consistent $where.';
  }

  @override
  String editorTextToolUnchangedNothingToConvert(String where) {
    return 'nothing to convert $where.';
  }

  @override
  String editorTextToolUnchangedNothingToChange(String where) {
    return 'nothing to change $where.';
  }

  @override
  String editorTextToolUnchangedNothingToStraighten(String where) {
    return 'nothing to straighten $where.';
  }

  @override
  String editorTextToolUnchangedNothingToZap(String where) {
    return 'nothing to zap $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyAscii(String where) {
    return 'already ASCII $where.';
  }

  @override
  String editorTextToolUnchangedNothingToConvertWithLeft(
    String where,
    int left,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      left,
      locale: localeName,
      other: '$left characters',
      one: '1 character',
    );
    return 'nothing to convert $where, $_temp0 without an equivalent.';
  }

  @override
  String editorTextToolUnchangedNoDiacritics(String where) {
    return 'no diacritics $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyComposed(String where) {
    return 'already composed $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyDecomposed(String where) {
    return 'already decomposed $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyFormatted(String where) {
    return 'already formatted $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyMinified(String where) {
    return 'already minified $where.';
  }

  @override
  String editorTextToolUnchangedNoEscapeSequences(String where) {
    return 'no escape sequences $where.';
  }

  @override
  String editorTextToolUnchangedNothingToUnwrap(String where) {
    return 'nothing to unwrap $where.';
  }

  @override
  String editorTextToolUnchangedNothingToJoin(String where) {
    return 'nothing to join $where.';
  }

  @override
  String editorTextToolUnchangedNothingToDecode(String where) {
    return 'nothing to decode $where.';
  }

  @override
  String editorTextToolUnchangedNoEntities(String where) {
    return 'no entities $where.';
  }

  @override
  String editorTextToolUnchangedNoEscapes(String where) {
    return 'no escapes $where.';
  }

  @override
  String editorTextToolUnchangedEveryLineMatched(String where) {
    return 'nothing to change, every line matched $where.';
  }

  @override
  String editorTextToolUnchangedNothingMatched(String where) {
    return 'nothing matched $where.';
  }

  @override
  String get editorTextToolApply => 'Apply';

  @override
  String get editorTextToolClose => 'Close';

  @override
  String get editorTextToolAppliesTo => 'Applies to';

  @override
  String editorTextToolSelectedLinesScope(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return '$_temp0 selected';
  }

  @override
  String editorTextToolWholeDocumentScope(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return 'Whole document, $_temp0';
  }

  @override
  String editorTextToolNothingSelectedScope(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return 'Nothing selected: whole document, $_temp0';
  }

  @override
  String get editorTextToolParagraphAtCaret => 'the paragraph at the caret';

  @override
  String get editorTextToolWordAtCaret => 'the word at the caret';

  @override
  String get editorTextToolAtCaret => 'the caret';

  @override
  String get editorTextToolPreviewDeferred => 'count is computed on Apply';

  @override
  String editorTextToolPreviewRefused(String reason) {
    return 'not applied, $reason';
  }

  @override
  String get editorTextToolPreviewNothing => 'nothing to change';

  @override
  String editorTextToolPreviewWillExpandTabs(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed tabs',
      one: '1 tab',
    );
    return 'will expand $_temp0';
  }

  @override
  String editorTextToolPreviewWillWrapLines(int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will wrap $_temp0';
  }

  @override
  String editorTextToolPreviewWillNormalizeBreaks(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed line breaks',
      one: '1 line break',
    );
    return 'will normalize $_temp0';
  }

  @override
  String editorTextToolPreviewSortWillMove(int changed, int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return '$changed of $_temp0 will move';
  }

  @override
  String editorTextToolPreviewWillReverse(int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will reverse $_temp0';
  }

  @override
  String editorTextToolPreviewWillShuffle(int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will shuffle $_temp0';
  }

  @override
  String editorTextToolPreviewWillRemoveOfScope(int changed, int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will remove $changed of $_temp0';
  }

  @override
  String editorTextToolPreviewWillRemoveLines(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed lines',
      one: '1 line',
    );
    return 'will remove $_temp0';
  }

  @override
  String editorTextToolPreviewWillCollapse(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed blank lines',
      one: '1 blank line',
    );
    return 'will collapse $_temp0';
  }

  @override
  String editorTextToolPreviewWillTrimLines(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed lines',
      one: '1 line',
    );
    return 'will trim $_temp0';
  }

  @override
  String editorTextToolPreviewWillNormalizeSpaces(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed spaces',
      one: '1 space',
    );
    return 'will normalize $_temp0';
  }

  @override
  String editorTextToolPreviewWillUppercase(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will uppercase $_temp0';
  }

  @override
  String editorTextToolPreviewWillLowercase(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will lowercase $_temp0';
  }

  @override
  String editorTextToolPreviewWillRemoveEscapeSequences(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed escape sequences',
      one: '1 escape sequence',
    );
    return 'will remove $_temp0';
  }

  @override
  String editorTextToolPreviewWillJoinAtBreaks(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed line breaks',
      one: '1 line break',
    );
    return 'will join lines at $_temp0';
  }

  @override
  String editorTextToolPreviewWillConvert(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will convert $_temp0';
  }

  @override
  String editorTextToolPreviewWillStrip(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed marks',
      one: '1 mark',
    );
    return 'will strip $_temp0';
  }

  @override
  String editorTextToolPreviewWillCompose(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will compose $_temp0';
  }

  @override
  String editorTextToolPreviewWillDecompose(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will decompose $_temp0';
  }

  @override
  String editorTextToolPreviewWillFormat(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will format $_temp0';
  }

  @override
  String editorTextToolPreviewWillMinify(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will minify $_temp0';
  }

  @override
  String editorTextToolPreviewWillZap(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed gremlins',
      one: '1 gremlin',
    );
    return 'will zap $_temp0';
  }

  @override
  String editorTextToolPreviewWillChangeOfScope(int changed, int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will change $changed of $_temp0';
  }

  @override
  String editorTextToolPreviewWillRenumber(int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will renumber $_temp0';
  }

  @override
  String editorTextToolPreviewWillJoinLines(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed lines',
      one: '1 line',
    );
    return 'will join $_temp0';
  }

  @override
  String editorStatusPosition(int line, int column, int lines, int bytes) {
    String _temp0 = intl.Intl.pluralLogic(
      lines,
      locale: localeName,
      other: '$lines lines',
      one: '1 line',
    );
    String _temp1 = intl.Intl.pluralLogic(
      bytes,
      locale: localeName,
      other: '$bytes bytes',
      one: '1 byte',
    );
    return 'Ln $line, Col $column · $_temp0 · $_temp1';
  }

  @override
  String editorStatusSelection(int characters) {
    return '$characters selected';
  }

  @override
  String editorStatusSelectionLines(int characters, int lines) {
    return '$characters selected on $lines lines';
  }

  @override
  String get editorStatusSaving => 'Saving…';

  @override
  String get editorStatusUnsaved => 'Unsaved edits';

  @override
  String get editorStatusLargeFile => 'Large file: no highlighting';

  @override
  String editorStatusProblemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count problems',
      one: '1 problem',
    );
    return '$_temp0';
  }

  @override
  String get editorStatusNextProblemHint => 'Go to the next problem (F8)';

  @override
  String editorProblemSyntaxError(String detail) {
    return 'Syntax error: $detail';
  }

  @override
  String editorProblemDuplicateKey(String key, int line) {
    return 'Duplicate key \"$key\", first set on line $line';
  }

  @override
  String editorProblemDuplicateTable(String table, int line) {
    return 'Duplicate table [$table], first declared on line $line';
  }

  @override
  String editorProblemDuplicateAttribute(String attribute) {
    return 'Duplicate attribute \"$attribute\"';
  }

  @override
  String get editorProblemJsonComment => 'Comments are not allowed in JSON';

  @override
  String get editorProblemJsonTrailingComma =>
      'Trailing commas are not allowed in JSON';

  @override
  String get editorProblemUnterminatedQuote =>
      'This quoted value is never closed';

  @override
  String get editorProblemTabIndentation =>
      'YAML does not allow tabs for indentation';

  @override
  String editorProblemMismatchedClosingTag(String tag, String open, int line) {
    return '</$tag> does not match <$open> on line $line';
  }

  @override
  String editorProblemUnclosedElement(String tag) {
    return '<$tag> is never closed';
  }

  @override
  String editorProblemUnexpectedClosingTag(String tag) {
    return '</$tag> closes no open element';
  }

  @override
  String get editorProblemMergeConflict => 'Unresolved merge conflict';

  @override
  String editorStatusIndentSpaces(int width) {
    return 'Spaces: $width';
  }

  @override
  String editorStatusIndentTabs(int width) {
    return 'Tab Size: $width';
  }

  @override
  String get editorLanguagePlainText => 'Plain Text';

  @override
  String get editorLanguageCStyle => 'C-style';

  @override
  String get editorSavedUploadedDirty =>
      'Uploaded the saved version; newer edits remain unsaved.';

  @override
  String get editorSavedUploaded => 'Saved and uploaded.';

  @override
  String get editorSavedLocallyNotUploaded => 'Saved locally; not uploaded.';

  @override
  String get editorSavedLocally => 'Saved locally.';

  @override
  String get editorCheckoutUnavailable =>
      'The checkout store is unavailable; remote files cannot be edited.';

  @override
  String get editorConflictTitle => 'Remote file changed';

  @override
  String editorConflictBody(String name, String server) {
    return '“$name” changed (or was deleted) on $server after it was opened locally. Overwrite the remote version?';
  }

  @override
  String get editorConflictCancel => 'Cancel';

  @override
  String get editorConflictOverwrite => 'Overwrite Remote Version';

  @override
  String get fileOpenWithLabel => 'Open With';

  @override
  String get openWithBuiltInLabel => 'Built-in text editor';

  @override
  String get openWithSystemDefaultLabel => 'System default';

  @override
  String get openWithOtherLabel => 'Other…';

  @override
  String get openWithConfigureLabel => 'Configure Editors…';

  @override
  String get editorPickDialogTitle => 'Choose an editor application';

  @override
  String openWithPickedTitle(String name, String editor) {
    return 'Open “$name” with $editor?';
  }

  @override
  String openWithRememberForExtension(String editor, String extension) {
    return 'Always use $editor for .$extension files';
  }

  @override
  String get openWithCancel => 'Cancel';

  @override
  String get openWithConfirmOpen => 'Open';

  @override
  String fileOpenProgramRefused(String name) {
    return '“$name” could run as a program on this computer, so it wasn\'t opened with the system default app.';
  }

  @override
  String checkoutDirtyUploadPrompt(String name) {
    return '“$name” changed locally. Upload it?';
  }

  @override
  String get checkoutDirtyUploadAction => 'Upload';

  @override
  String checkoutUploadSucceeded(String name) {
    return 'Uploaded $name';
  }

  @override
  String checkoutLocalEditsBanner(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files have local edits that aren\'t on the server yet.',
      one: '1 file has local edits that aren\'t on the server yet.',
    );
    return '$_temp0';
  }

  @override
  String get checkoutLocalEditsReview => 'Review…';

  @override
  String checkoutLocalEditsTitle(String server) {
    return 'Local edits — $server';
  }

  @override
  String get checkoutLocalEditsEmpty => 'No local edits for this server.';

  @override
  String get checkoutLocalEditsDirty => 'Modified locally';

  @override
  String get checkoutLocalEditsMissing => 'Local file missing';

  @override
  String get checkoutLocalEditsRecoveredRecord => 'Recovered';

  @override
  String get checkoutLocalEditsRecoveredSection => 'Recovered files';

  @override
  String get checkoutLocalEditsRecoveredHint =>
      'Recovered files can\'t upload from here — upload the file through a pane when you\'re done.';

  @override
  String get checkoutLocalEditsOpen => 'Open';

  @override
  String get checkoutLocalEditsUpload => 'Upload';

  @override
  String get checkoutLocalEditsDiscard => 'Discard…';

  @override
  String get checkoutLocalEditsConnectToUpload => 'Connect to upload';

  @override
  String get checkoutLocalEditsDiscardTitle => 'Discard local copy?';

  @override
  String get checkoutLocalEditsDiscardBody =>
      'Any changes not uploaded to the server are deleted.';

  @override
  String get checkoutLocalEditsDiscardCancel => 'Cancel';

  @override
  String get checkoutLocalEditsDiscardConfirm => 'Discard';

  @override
  String get checkoutLocalEditsClose => 'Close';

  @override
  String get sidebarLocalEdits => 'Local Edits…';

  @override
  String get editorSettingsClose => 'Close';

  @override
  String get settingsOpeningFilesSection => 'Opening files';

  @override
  String get doubleClickActionLabel => 'Double-click action';

  @override
  String get doubleClickActionSubtitle =>
      'Also applies to opening a file from the keyboard. Folders always open.';

  @override
  String get doubleClickActionOpen => 'Open';

  @override
  String get doubleClickActionEdit => 'Edit in Poltergeist';

  @override
  String get doubleClickActionTransfer => 'Transfer to other pane';

  @override
  String get doubleClickActionNothing => 'Do nothing';

  @override
  String get editorDefaultLabel => 'Default editor';

  @override
  String get editorBuiltInOption => 'Built-in editor';

  @override
  String get editorSystemDefaultOption => 'System default';

  @override
  String editorNameOtherPlatform(String name) {
    return '$name (another platform)';
  }

  @override
  String get editorListLabel => 'External editors';

  @override
  String get editorEmptyState => 'No external editors configured.';

  @override
  String get editorAddLabel => 'Add Editor…';

  @override
  String get editorEditLabel => 'Edit…';

  @override
  String get editorRemoveLabel => 'Remove';

  @override
  String editorRemoveTitle(String name) {
    return 'Remove $name?';
  }

  @override
  String get editorRemoveBody =>
      'The application is only removed from Poltergeist settings.';

  @override
  String get editorRemoveDefaultBody =>
      'This is the current default. Removing it resets the default to System default.';

  @override
  String get editorEditTitle => 'Edit external editor';

  @override
  String get editorAddTitle => 'Add external editor';

  @override
  String get editorNameFieldLabel => 'Display name';

  @override
  String get editorExtensionsFieldLabel =>
      'Accepted file extensions (optional)';

  @override
  String get editorExtensionsFieldHint => 'dart, json, yaml, tar.gz';

  @override
  String get editorExtensionsFieldHelper =>
      'Leave blank to show this editor for every file.';

  @override
  String get editorDialogCancel => 'Cancel';

  @override
  String get editorDialogSave => 'Save';

  @override
  String get filePreviewLabel => 'Quick Look';

  @override
  String get filePreviewLabelNeutral => 'Preview';

  @override
  String get viewTogglePreviewLabel => 'Info';

  @override
  String get previewPanelLabel => 'Preview';

  @override
  String get previewPanelClose => 'Close preview';

  @override
  String get previewPanelEmpty => 'Nothing to preview';

  @override
  String get previewPressSpace => 'Press Space to download a preview.';

  @override
  String get previewDownloadLabel => 'Download';

  @override
  String get previewCancelLabel => 'Cancel';

  @override
  String get previewDismissLabel => 'Dismiss';

  @override
  String previewDownloadConfirm(String size, String name) {
    return 'Download $size to preview “$name”?';
  }

  @override
  String get previewDownloadingLabel => 'Downloading preview';

  @override
  String previewDownloadProgress(String transferred, String total) {
    return '$transferred of $total';
  }

  @override
  String previewDownloadingNamed(String name, String progress) {
    return 'Downloading $name — $progress';
  }

  @override
  String previewGatePrompt(String transferred) {
    return '$transferred downloaded so far. Keep going?';
  }

  @override
  String get previewKeepDownloadingLabel => 'Keep downloading';

  @override
  String get previewDownloadFailed => 'The preview download failed.';

  @override
  String get previewDownloadCancelled => 'The preview download was cancelled.';

  @override
  String get previewRefusalOverCacheCap =>
      'This file is larger than the preview cache allows.';

  @override
  String get previewRefusalOverKindCap => 'This file is too large to preview.';

  @override
  String get previewRefusalNotText => 'This file isn\'t UTF-8 text.';

  @override
  String get previewRefusalMissing => 'This file no longer exists.';

  @override
  String get previewOpenLabel => 'Open';

  @override
  String get previewOpenWithLabel => 'Open With…';

  @override
  String get previewOpenInEditorLabel => 'Open in editor';

  @override
  String get previewTruncatedLabel => 'Preview truncated';

  @override
  String previewImageLabel(String name) {
    return 'Preview of $name';
  }

  @override
  String previewImageDimensions(int width, int height) {
    return '$width × $height pixels';
  }

  @override
  String previewSelectionSummary(int count, String size, int unknown) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    String _temp1 = intl.Intl.pluralLogic(
      unknown,
      locale: localeName,
      other: ' · $unknown size unknown',
      zero: '',
    );
    return '$_temp0 · $size$_temp1';
  }

  @override
  String previewPdfPageRange(int shown, int total) {
    return 'Page 1–$shown of $total';
  }

  @override
  String previewPdfPageLabel(int page, int total) {
    return 'Page $page of $total';
  }

  @override
  String get previewPdfFailed => 'Couldn\'t render this PDF.';

  @override
  String get previewSettingsSectionTitle => 'Preview & downloads';

  @override
  String get previewCacheLimitLabel => 'Preview cache limit';

  @override
  String get previewClearCacheLabel => 'Clear Preview Cache';

  @override
  String previewCacheCleared(int mib) {
    return 'Cleared $mib MiB of cached previews.';
  }

  @override
  String get previewThresholdLabel => 'Confirm downloads larger than';

  @override
  String get previewMiBSuffix => 'MiB';

  @override
  String syncTabTitle(String name) {
    return 'Sync: $name';
  }

  @override
  String syncScanning(int leftCount, int rightCount) {
    return 'Scanning… left $leftCount entries · right $rightCount entries';
  }

  @override
  String get syncCancel => 'Cancel';

  @override
  String get syncPause => 'Pause';

  @override
  String get syncResume => 'Resume';

  @override
  String get syncModeLabel => 'Mode';

  @override
  String get syncModeUpdate => 'Update';

  @override
  String get syncModeMirror => 'Mirror';

  @override
  String get syncModeAdditive => 'Additive';

  @override
  String syncHeaderCopyNew(int count, String bytes) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Copy $count new files ($bytes)',
      one: 'Copy $count new file ($bytes)',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderCreateFolders(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'create $count folders',
      one: 'create $count folder',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderUpdateFiles(int count) {
    return 'update $count';
  }

  @override
  String syncHeaderOnDestination(String destination) {
    return 'on $destination.';
  }

  @override
  String get syncHeaderBothSides => 'both sides';

  @override
  String syncHeaderCreateOnly(int count, String destination) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Create $count folders on $destination.',
      one: 'Create $count folder on $destination.',
    );
    return '$_temp0';
  }

  @override
  String get syncHeaderNothingDeleted => 'Nothing will be deleted.';

  @override
  String syncHeaderDeleteTrash(int count, String side, String trashLocation) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count files on $side (moved to trash at $trashLocation).',
      one: 'Delete $count file on $side (moved to trash at $trashLocation).',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderDeletePermanent(int count, String side) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count files on $side permanently.',
      one: 'Delete $count file on $side permanently.',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderReplaceTrash(int count, String side, String trashLocation) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Replace $count files of a different kind on $side (previous versions moved to trash at $trashLocation).',
      one:
          'Replace $count file of a different kind on $side (previous version moved to trash at $trashLocation).',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderReplacePermanent(int count, String side) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Replace $count files of a different kind on $side (previous versions deleted permanently).',
      one:
          'Replace $count file of a different kind on $side (previous version deleted permanently).',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderRemoveEmptyFolders(int count, String side) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Remove $count empty folders on $side.',
      one: 'Remove $count empty folder on $side.',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderConflicts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count conflicts need a decision.',
      one: '$count conflict needs a decision.',
    );
    return '$_temp0';
  }

  @override
  String get syncHeaderNothingToDo => 'Both sides match. Nothing to do.';

  @override
  String get syncHeaderSizeOnlyNotice =>
      'Timestamps are unreliable on at least one side — comparing by size only.';

  @override
  String syncWarningsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count scan warnings',
      one: '$count scan warning',
    );
    return '$_temp0';
  }

  @override
  String syncFilterAll(int count) {
    return 'All ($count)';
  }

  @override
  String syncFilterNew(int count) {
    return 'New ($count)';
  }

  @override
  String syncFilterUpdates(int count) {
    return 'Updates ($count)';
  }

  @override
  String syncFilterDeletes(int count) {
    return 'Deletes ($count)';
  }

  @override
  String syncFilterConflicts(int count) {
    return 'Conflicts ($count)';
  }

  @override
  String syncFilterSkipped(int count) {
    return 'Skipped ($count)';
  }

  @override
  String get syncFilterFieldHint => 'Filter items';

  @override
  String get syncFilterOnlyActions => 'Only show actions';

  @override
  String get syncReasonOnlyHere => 'only exists here';

  @override
  String syncReasonNewerHere(String sourceAge, String destinationAge) {
    return 'newer here ($sourceAge vs $destinationAge)';
  }

  @override
  String syncReasonSizesDiffer(String leftSize, String rightSize) {
    return 'sizes differ ($leftSize vs $rightSize)';
  }

  @override
  String get syncReasonContentsDiffer => 'contents differ';

  @override
  String get syncReasonBothChanged => 'changed on both sides';

  @override
  String syncReasonTypeDiffers(String leftKind, String rightKind) {
    return 'type differs ($leftKind here, $rightKind there)';
  }

  @override
  String get syncReasonExcluded => 'excluded by rule';

  @override
  String get syncReasonCaseCollision => 'names differ only by case';

  @override
  String get syncReasonNormalizationCollision =>
      'names differ only by Unicode form';

  @override
  String get syncReasonInvalidName => 'name invalid on Windows';

  @override
  String get syncReasonScanError => 'couldn\'t scan — subtree excluded';

  @override
  String get syncReasonEqual => 'identical';

  @override
  String get syncReasonSymlink => 'symbolic link — skipped';

  @override
  String get syncKindFile => 'file';

  @override
  String get syncKindFolder => 'folder';

  @override
  String get syncKindSymlink => 'symbolic link';

  @override
  String get syncKindOther => 'other';

  @override
  String syncCompareTitle(String path) {
    return 'Compare $path';
  }

  @override
  String get syncCompareSelected => 'Compare Selected Item';

  @override
  String get syncCompareSideLeft => 'Left';

  @override
  String get syncCompareSideRight => 'Right';

  @override
  String syncCompareMetadata(String size, String modified) {
    return '$size · Modified $modified';
  }

  @override
  String get syncCompareLoading => 'Loading…';

  @override
  String get syncCompareEditorLimit =>
      'The built-in editor supports text files up to 4 MB.';

  @override
  String get syncCompareRemoteUnavailable =>
      'Remote comparison is unavailable.';

  @override
  String get syncCompareFailed => 'This side could not be loaded.';

  @override
  String get syncCompareInvalidUtf8 => 'This file is not valid UTF-8 text.';

  @override
  String get syncCompareBinary =>
      'This file appears to be binary, not editable text.';

  @override
  String get syncCompareChanged =>
      'The local copy changed while it was being opened.';

  @override
  String get syncCompareMissing => 'The file no longer exists.';

  @override
  String syncCompareLineEndingsDiffer(String left, String right) {
    return 'Line endings differ: $left vs $right';
  }

  @override
  String get syncCompareBomDiffers => 'BOM differs';

  @override
  String get syncSideLeft => 'left';

  @override
  String get syncSideRight => 'right';

  @override
  String get syncOverrideSkip => 'Skip';

  @override
  String get syncOverrideCopyLeftToRight => 'Copy left → right';

  @override
  String get syncOverrideCopyRightToLeft => 'Copy right → left';

  @override
  String get syncOverrideDelete => 'Delete';

  @override
  String get syncOverrideReset => 'Reset to suggested';

  @override
  String syncOverrideSkippedTypeDiffers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count type-differs rows skipped — replacing a different kind stays a per-item choice',
      one:
          '$count type-differs row skipped — replacing a different kind stays a per-item choice',
    );
    return '$_temp0';
  }

  @override
  String get syncResolveConflictsLabel => 'Resolve conflicts:';

  @override
  String get syncResolveNewerWins => 'Newer wins';

  @override
  String get syncResolveKeepLeft => 'Keep left';

  @override
  String get syncResolveKeepRight => 'Keep right';

  @override
  String get syncResolveSkipAll => 'Skip all';

  @override
  String get syncSaveAsFavorite => 'Save as Favorite…';

  @override
  String syncRunCopyFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Copy $count Files',
      one: 'Copy 1 File',
    );
    return '$_temp0';
  }

  @override
  String syncRunCopyPart(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Copy $count',
      one: 'Copy 1',
    );
    return '$_temp0';
  }

  @override
  String syncRunCreateFolders(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Create $count Folders',
      one: 'Create $count Folder',
    );
    return '$_temp0';
  }

  @override
  String syncRunDeletePart(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count',
      one: 'Delete 1',
    );
    return '$_temp0';
  }

  @override
  String get syncRunNothingToDo => 'Nothing to Do';

  @override
  String syncHeavySuggestion(String name, int count) {
    return '$name is $count of these files — exclude?';
  }

  @override
  String get syncDeleteConfirmTitle => 'Confirm deletions';

  @override
  String syncDeleteConfirmFraction(
    int count,
    int total,
    String side,
    String pct,
  ) {
    return 'This will delete $count of $total files on $side — more than $pct of that side. Type DELETE to continue.';
  }

  @override
  String syncDeleteConfirmFloor(int count, int total, String side) {
    return 'This will delete $count of $total files on $side — 90 % or more of that side. Type DELETE to continue.';
  }

  @override
  String get syncDeleteConfirmFieldHint => 'DELETE';

  @override
  String get syncDeleteConfirmHalf => 'half';

  @override
  String get syncDeleteConfirmButton => 'Delete';

  @override
  String get syncMaxDeleteTitle => 'Too many deletions';

  @override
  String syncMaxDeleteBody(int count, String side, int cap) {
    return 'This plan would delete $count files on $side — over the $cap-file cap. Run stays disabled rather than silently diverging the destination. Raise the cap in the pair\'s rules to run it.';
  }

  @override
  String get syncMaxDeleteSaveAdjust => 'Save as Favorite & Adjust Rules…';

  @override
  String get syncRetryFailed => 'Retry Failed';

  @override
  String get syncRestoreTrashed => 'Restore Trashed Files…';

  @override
  String get syncPurgeTrash => 'Purge Sync Trash…';

  @override
  String get syncAdjustDocrootTrash => 'Protect Published Sync Trash…';

  @override
  String syncTrashNotice(int files, int runs) {
    String _temp0 = intl.Intl.pluralLogic(
      files,
      locale: localeName,
      other: '$files trashed files',
      one: '$files trashed file',
    );
    String _temp1 = intl.Intl.pluralLogic(
      runs,
      locale: localeName,
      other: '$runs runs',
      one: '$runs run',
    );
    return '$_temp0 from $_temp1 older than 30 days — delete them?';
  }

  @override
  String syncTrashUnjournaled(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Plus $count unjournaled runs.',
      one: 'Plus 1 unjournaled run.',
    );
    return '$_temp0';
  }

  @override
  String syncTrashAsOf(String time) {
    return 'As of $time; reconnect to delete.';
  }

  @override
  String get syncTrashAsOfRecent =>
      'As of less than an hour ago; reconnect to delete.';

  @override
  String syncTrashAsOfHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'As of $count hours ago; reconnect to delete.',
      one: 'As of 1 hour ago; reconnect to delete.',
    );
    return '$_temp0';
  }

  @override
  String syncTrashAsOfDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'As of $count days ago; reconnect to delete.',
      one: 'As of 1 day ago; reconnect to delete.',
    );
    return '$_temp0';
  }

  @override
  String get syncTrashDelete => 'Delete…';

  @override
  String get syncTrashPurgeTitle => 'Purge sync trash?';

  @override
  String syncTrashPurgeSummary(int files, int runs) {
    String _temp0 = intl.Intl.pluralLogic(
      files,
      locale: localeName,
      other: '$files journaled files',
      one: '$files journaled file',
    );
    String _temp1 = intl.Intl.pluralLogic(
      runs,
      locale: localeName,
      other: '$runs runs',
      one: '$runs run',
    );
    return '$_temp0 from $_temp1 will be permanently deleted.';
  }

  @override
  String get syncTrashPurgeScope => 'Sync trash is shared by host and root.';

  @override
  String get syncTrashPurgeOtherPairs =>
      'This includes trash from other sync pairs that use the same host and root.';

  @override
  String syncTrashPurgeForeign(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'This includes $count runs created by other machines.',
      one: 'This includes 1 run created by another machine.',
    );
    return '$_temp0';
  }

  @override
  String get syncTrashPurgeForfeit => 'These files can no longer be restored.';

  @override
  String get syncTrashPurgeConfirm => 'Purge';

  @override
  String get syncTrashPurging => 'Purging sync trash…';

  @override
  String syncTrashPurgeResult(int purged, int failed) {
    String _temp0 = intl.Intl.pluralLogic(
      purged,
      locale: localeName,
      other: 'Purged $purged runs',
      one: 'Purged 1 run',
    );
    String _temp1 = intl.Intl.pluralLogic(
      failed,
      locale: localeName,
      other: ' — $failed failed',
      one: ' — 1 failed',
      zero: '',
    );
    return '$_temp0$_temp1';
  }

  @override
  String syncTrashPurgeCancelled(int purged) {
    String _temp0 = intl.Intl.pluralLogic(
      purged,
      locale: localeName,
      other: '$purged runs',
      one: '1 run',
    );
    return 'Purge cancelled after $_temp0.';
  }

  @override
  String get syncTrashPurgeActive =>
      'Wait for active syncs to finish, then try again.';

  @override
  String syncTrashPurgeFailed(String message) {
    return 'Couldn’t purge sync trash: $message';
  }

  @override
  String get syncTrashEndpointChanged =>
      'The sync endpoint changed while sync trash was being resolved.';

  @override
  String get syncTrashHostKeyUnavailable =>
      'The sync endpoint has no accepted host key.';

  @override
  String get syncTrashJumpRouteInvalid =>
      'The sync endpoint jump route is invalid.';

  @override
  String get syncTrashJumpHostUnavailable =>
      'The sync endpoint jump host is unavailable.';

  @override
  String get syncTrashAuthenticationUnavailable =>
      'The sync endpoint has no authenticated lease.';

  @override
  String get syncCopyReport => 'Copy Report';

  @override
  String get syncCopyRsyncCommand => 'Copy as rsync Command';

  @override
  String get syncCopiedRsyncCommand => 'Copied rsync command';

  @override
  String get syncCopiedRsyncCommandPermanent =>
      'Copied rsync command — deletions are permanent when pasted';

  @override
  String get syncRsyncCopyFailed =>
      'Couldn\'t copy the rsync command — clipboard unavailable';

  @override
  String get syncHeavySuggestionAccept => 'Exclude';

  @override
  String get syncRestoreRecoveryTitle => 'Interrupted restore';

  @override
  String get syncRestoreRecoveryBody =>
      'A previous restore stopped before it finished. Sync is paused until you finish it.';

  @override
  String syncRestoreRecoveryBlocked(String path) {
    return 'Sync is paused because its interrupted restore cannot be verified. Keep both folders unchanged. Restore the journal from backup or contact support: $path';
  }

  @override
  String get syncRestoreRecoveryAction => 'Finish Restore…';

  @override
  String get syncRestoreRecoveryDialogTitle => 'Finish Interrupted Restore';

  @override
  String syncRestoreRecoverySummary(int restored, int removedCreatedFiles) {
    String _temp0 = intl.Intl.pluralLogic(
      restored,
      locale: localeName,
      other: 'Restores $restored original items.',
      one: 'Restores $restored original item.',
      zero: 'Restores no original items.',
    );
    String _temp1 = intl.Intl.pluralLogic(
      removedCreatedFiles,
      locale: localeName,
      other: 'Removes $removedCreatedFiles files created by this run.',
      one: 'Removes $removedCreatedFiles file created by this run.',
      zero: 'Removes no files created by this run.',
    );
    return 'Finish the interrupted restore. $_temp0 $_temp1';
  }

  @override
  String get syncRestoreDialogTitle => 'Restore Trashed Files';

  @override
  String syncRestoreSummary(int restored, int removedCreatedFiles) {
    String _temp0 = intl.Intl.pluralLogic(
      restored,
      locale: localeName,
      other: 'Restores $restored original items.',
      one: 'Restores $restored original item.',
      zero: 'Restores no original items.',
    );
    String _temp1 = intl.Intl.pluralLogic(
      removedCreatedFiles,
      locale: localeName,
      other: 'Removes $removedCreatedFiles files created by this run.',
      one: 'Removes $removedCreatedFiles file created by this run.',
      zero: 'Removes no files created by this run.',
    );
    return '$_temp0 $_temp1';
  }

  @override
  String get syncRestoreButton => 'Restore';

  @override
  String syncRestoreResult(int restored, int skipped) {
    String _temp0 = intl.Intl.pluralLogic(
      restored,
      locale: localeName,
      other: 'Restored $restored items',
      one: 'Restored $restored item',
    );
    String _temp1 = intl.Intl.pluralLogic(
      skipped,
      locale: localeName,
      other: '. $skipped skipped',
      one: '. $skipped skipped',
      zero: '',
    );
    return '$_temp0$_temp1';
  }

  @override
  String syncRestoreFailed(String message) {
    return 'Restore stopped. Check the connection and file state, then retry. Error: $message';
  }

  @override
  String get syncDirectionLeftToRight => 'Left to right';

  @override
  String get syncDirectionRightToLeft => 'Right to left';

  @override
  String get syncDirectionBothWays => 'Both ways';

  @override
  String get syncEditorOptionsSection => 'Options';

  @override
  String get syncEditorTitle => 'Sync pair';

  @override
  String get syncEditorNameLabel => 'Name';

  @override
  String get syncEditorDeletionsLabel => 'Deletions';

  @override
  String get syncEditorDeletionsNone => 'Never delete';

  @override
  String get syncEditorDeletionsTrash => 'Move to trash';

  @override
  String get syncEditorDeletionsPermanent => 'Delete permanently';

  @override
  String get syncEditorBackupsLabel => 'Overwrite backups';

  @override
  String get syncEditorBackupsTrash => 'Keep in trash';

  @override
  String get syncEditorBackupsNone => 'None';

  @override
  String get syncEditorComparisonLabel => 'Compare by';

  @override
  String get syncEditorComparisonSizeMtime => 'Size and modification time';

  @override
  String get syncEditorComparisonSizeOnly => 'Size only';

  @override
  String get syncEditorComparisonContentHash => 'Content hash';

  @override
  String get syncEditorConflictLabel => 'Conflicts';

  @override
  String get syncEditorConflictAsk => 'Ask each time';

  @override
  String get syncEditorConflictNewerWins => 'Newer wins';

  @override
  String get syncEditorConflictKeepLeft => 'Keep left';

  @override
  String get syncEditorConflictKeepRight => 'Keep right';

  @override
  String get syncEditorConflictSkip => 'Skip';

  @override
  String get syncEditorMaxDeleteLabel => 'Deletion cap (maxDelete)';

  @override
  String get syncEditorFractionWarnLabel => 'Typed-confirmation threshold';

  @override
  String get syncEditorExcludeLabel => 'Exclude rules';

  @override
  String get syncEditorIncludeHidden => 'Include hidden files';

  @override
  String get syncEditorTrashLeftLabel => 'Left trash path';

  @override
  String get syncEditorTrashRightLabel => 'Right trash path';

  @override
  String get syncDocrootWarningTitle => 'Trash may be public';

  @override
  String syncDocrootWarningBody(String side, String root) {
    return '$side trash is inside $root. Deleted and replaced files may be downloadable over HTTP.';
  }

  @override
  String get syncDocrootWarningUseSaferPath => 'Use safer path';

  @override
  String syncDocrootWarningUseSaferPathForSide(String side) {
    return 'Use safer path for $side';
  }

  @override
  String get syncEditorPathHint => '/path';

  @override
  String get syncEditorMtimeToleranceLabel =>
      'Modification-time tolerance (seconds)';

  @override
  String get syncEditorPreserveMtime => 'Preserve modification times';

  @override
  String get syncEditorConcurrencyLabel => 'Transfer concurrency';

  @override
  String get syncEditorCaseLeftLabel => 'Left case sensitivity';

  @override
  String get syncEditorCaseRightLabel => 'Right case sensitivity';

  @override
  String get syncEditorCaseAuto => 'Detect automatically';

  @override
  String get syncEditorCaseSensitive => 'Case-sensitive';

  @override
  String get syncEditorCaseInsensitive => 'Case-insensitive';

  @override
  String get syncEditorSave => 'Save';

  @override
  String get syncEditorSaveAndRescan => 'Save & Rescan';

  @override
  String get syncNewSavedSync => 'New Saved Sync…';

  @override
  String syncPairLabel(String left, String right) {
    return '$left ⇄ $right';
  }

  @override
  String get syncSynchronizePanes => 'Synchronize…';

  @override
  String get syncRescan => 'Rescan';

  @override
  String syncScanFailed(String error) {
    return 'The scan could not complete — $error';
  }

  @override
  String get syncRemoteUnavailable =>
      'Remote sync pairs aren\'t available yet — remote filesystems arrive with the engine-protocol transfer verbs.';

  @override
  String syncRunFailed(String error) {
    return 'The run failed — $error';
  }

  @override
  String syncSummaryCounts(int done, int failed, int skipped) {
    String _temp0 = intl.Intl.pluralLogic(
      done,
      locale: localeName,
      other: '$done done',
      one: '$done done',
    );
    String _temp1 = intl.Intl.pluralLogic(
      failed,
      locale: localeName,
      other: '$failed failed',
      one: '$failed failed',
    );
    String _temp2 = intl.Intl.pluralLogic(
      skipped,
      locale: localeName,
      other: '$skipped skipped',
      one: '$skipped skipped',
    );
    return '$_temp0 · $_temp1 · $_temp2';
  }

  @override
  String get syncPairLocalLabel => 'local';

  @override
  String syncSavedFavoriteToast(String name) {
    return 'Saved sync \"$name\" added to favorites';
  }

  @override
  String get quickOpenCommandLabel => 'Quick Open…';

  @override
  String get quickOpenTitle => 'Quick Open';

  @override
  String get quickOpenFieldHint => 'Type a command or location';

  @override
  String get quickOpenHintMacos =>
      'Enter runs · ⌥Enter opens in the other pane · ⌘Enter opens in a new tab · Esc closes';

  @override
  String get quickOpenHint =>
      'Enter runs · Alt+Enter opens in the other pane · Ctrl+Enter opens in a new tab · Esc closes';

  @override
  String get quickOpenSectionCommands => 'Commands';

  @override
  String get quickOpenSectionFavorites => 'Favorites';

  @override
  String get quickOpenSectionRecents => 'Recents';

  @override
  String quickOpenNoMatches(String query) {
    return 'No matches for “$query”';
  }

  @override
  String quickOpenRowSemantics(String label, String section) {
    return '$label, $section';
  }

  @override
  String quickOpenMenuPath(String menu, String label) {
    return '$menu ▸ $label';
  }

  @override
  String get quickOpenRecentUnavailable => 'This server is no longer available';

  @override
  String get commandDisabledNoBack => 'No earlier location';

  @override
  String get commandDisabledNoForward => 'No later location';

  @override
  String get commandDisabledNoListing => 'Requires a browsed folder';

  @override
  String get commandDisabledNoSelection => 'Requires a selected item';

  @override
  String get commandDisabledNoPreview => 'Previews are unavailable';

  @override
  String get commandDisabledNoSidebar => 'Requires the sidebar';

  @override
  String get commandDisabledSyncAnchors =>
      'Requires browsed folders on both panes';

  @override
  String get commandDisabledNoTab => 'Requires an open tab';

  @override
  String get commandDisabledNoClosedTab => 'No recently closed tab';

  @override
  String get commandDisabledMultipleTabs => 'Requires at least two tabs';

  @override
  String get commandDisabledNoQueue => 'Requires the transfer queue';

  @override
  String get commandDisabledNoPlan => 'Requires an open sync plan';

  @override
  String get commandDisabledNoSyncTrash =>
      'Requires live sync trash with no active run';

  @override
  String get commandDisabledNoDocrootTrash =>
      'Requires an editable published-root trash warning';

  @override
  String get commandDisabledNoComparableItem =>
      'Requires a selected file present on both sides';

  @override
  String get commandDisabledNoBookmarks => 'Requires saved favorites';

  @override
  String get commandDisabledBusy =>
      'Unavailable while another command is running';

  @override
  String get commandDisabledNoEditors =>
      'Requires a configured external editor';

  @override
  String get commandDisabledNoWorkspaces => 'No saved workspaces';

  @override
  String get sidebarImportSshConfig => 'Import from ssh config…';

  @override
  String get sidebarCatalogSection => 'Séance servers';

  @override
  String get sidebarCatalogUngrouped => 'Ungrouped';

  @override
  String get sidebarCatalogEmpty =>
      'No servers on this account yet. Add one in Séance and sync to see it here.';

  @override
  String get sidebarCatalogNoMatches => 'No servers match the filter.';

  @override
  String get sidebarCatalogFilter => 'Filter servers';

  @override
  String sidebarCatalogFilterCount(int matches, int total) {
    return '$matches of $total';
  }

  @override
  String sidebarCatalogFilterCountOpenFirst(int matches, int total) {
    return '$matches of $total · ↵ opens the first';
  }

  @override
  String get sidebarCatalogFilterClear => 'Clear filter';

  @override
  String get sidebarCatalogSyncNow => 'Sync now';

  @override
  String get sidebarCatalogSyncing => 'Syncing…';

  @override
  String sidebarCatalogSyncFailed(String error) {
    return 'Last sync failed: $error';
  }

  @override
  String panePathSegmentGoTo(String segment) {
    return 'Go to $segment';
  }

  @override
  String sidebarSectionSemantics(String title, String count) {
    return '$title, $count';
  }

  @override
  String get sidebarHiddenConnected => 'Connected server hidden';

  @override
  String get sidebarHiddenConnecting => 'Connecting server hidden';

  @override
  String get sidebarCatalogAddServer => 'Add server';

  @override
  String get sidebarCatalogEdit => 'Edit';

  @override
  String get sidebarCatalogDuplicate => 'Duplicate';

  @override
  String get sidebarCatalogDelete => 'Delete';

  @override
  String sidebarCatalogDeleteTitle(String label) {
    return 'Delete \"$label\"?';
  }

  @override
  String get sidebarCatalogDeleteBody =>
      'This removes the server and any stored secret, on this device and — if it synced — your other devices.';

  @override
  String sidebarCatalogDeleteBodyEdits(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'This removes the server, its stored secret, and # managed local edits. Any changes not uploaded to the server will be deleted.',
      one:
          'This removes the server, its stored secret, and # managed local edit. Any changes not uploaded to the server will be deleted.',
    );
    return '$_temp0';
  }

  @override
  String get sidebarCatalogDeleteCancel => 'Cancel';

  @override
  String get sidebarCatalogDeleteConfirm => 'Delete';

  @override
  String sidebarCatalogDuplicateFailed(String label, String error) {
    return 'Could not duplicate \"$label\": $error';
  }

  @override
  String sidebarCatalogDuplicated(String label) {
    return 'Duplicated as \"$label\"';
  }

  @override
  String get sidebarCatalogDuplicatedEdit => 'Edit';

  @override
  String get serverEditorAddTitle => 'Add server';

  @override
  String get serverEditorEditTitle => 'Edit server';

  @override
  String get serverEditorLabel => 'Label';

  @override
  String get serverEditorHost => 'Host';

  @override
  String get serverEditorPort => 'Port';

  @override
  String get serverEditorUsername => 'Username';

  @override
  String get serverEditorAuthentication => 'Authentication';

  @override
  String get serverEditorAuthAgent => 'ssh-agent';

  @override
  String get serverEditorAuthPassword => 'Password';

  @override
  String get serverEditorAuthPrivateKey => 'Private key';

  @override
  String get serverEditorAgentInfo =>
      'Keys are provided by your ssh-agent; nothing is stored.';

  @override
  String get serverEditorPasswordLabel => 'Password';

  @override
  String get serverEditorReferenceKeyTitle => 'Reference a key file on disk';

  @override
  String get serverEditorReferenceKeySubtitle =>
      'Don\'t store the key — read it at connect';

  @override
  String get serverEditorIdentityFileHint => '~/.ssh/id_ed25519';

  @override
  String get serverEditorIdentityFilePath => 'Identity file path';

  @override
  String get serverEditorBrowse => 'Browse…';

  @override
  String get serverEditorPrivateKeyPem => 'Private key (PEM/OpenSSH)';

  @override
  String get serverEditorKeyPassphrase => 'Key passphrase (optional)';

  @override
  String get serverEditorStartDirectory => 'Start folder (optional)';

  @override
  String get serverEditorStartDirectoryHint => 'e.g. ~/sites or /var/www';

  @override
  String get serverEditorStartDirectoryNote =>
      'Opens when you connect to this server. A relative path starts in your home folder. Blank opens your home folder.';

  @override
  String get serverEditorStartDirectoryInvalid =>
      'Use an absolute path such as /var/www, or one in your own home such as ~/sites.';

  @override
  String get serverEditorLoginScript => 'Login script (optional)';

  @override
  String get serverEditorLoginScriptHint =>
      'e.g. cd ~/work && tmux attach -t work || tmux new -s work';

  @override
  String get serverEditorLoginScriptNote =>
      'Runs as if typed at the prompt right after connecting. Its text and output land in scrollback — keep secrets out. Blank for none.';

  @override
  String get serverEditorTransferLimit => 'Simultaneous transfers';

  @override
  String serverEditorTransferLimitDefault(String value) {
    return 'Default ($value)';
  }

  @override
  String get serverEditorTransferLimitNote =>
      'How many files move to or from this server at once. Browsing, editing and previews are never held back. Kept on this device only.';

  @override
  String serverEditorTransferLimitSaveFailed(String error) {
    return 'The server was saved, but its transfer limit wasn\'t: $error';
  }

  @override
  String get serverEditorAppearance => 'Appearance';

  @override
  String get serverEditorGroup => 'Group';

  @override
  String get serverEditorGroupHint =>
      'Production, Home lab, … — blank for none';

  @override
  String get serverEditorColour => 'Colour';

  @override
  String get serverEditorMark => 'Mark';

  @override
  String get serverEditorChooseMark => 'Choose…';

  @override
  String get serverEditorDefaultMarkTooltip => 'Use the default mark';

  @override
  String get serverEditorSyncSecretTitle => 'Allow this credential to sync';

  @override
  String get serverEditorSyncSecretExcluded =>
      'Not used while this server is excluded from sync.';

  @override
  String get serverEditorSyncSecretSubtitle =>
      'End-to-end encrypted. Also needs sync set up with \"Sync saved passwords & keys\" enabled.';

  @override
  String get serverEditorExcludeTitle => 'Exclude from sync';

  @override
  String get serverEditorExcludeOnSubtitle =>
      'Kept on this device only. A copy that synced earlier is removed from the sync server and from your other devices.';

  @override
  String get serverEditorExcludeOffSubtitle =>
      'Keep this server on this device only — never upload it.';

  @override
  String get serverEditorTest => 'Test connection';

  @override
  String get serverEditorTesting => 'Testing…';

  @override
  String get serverEditorTestingSemantic => 'Testing connection';

  @override
  String serverEditorJumpRouteCycle(String serverId) {
    return 'The jump-host route contains a cycle at “$serverId”.';
  }

  @override
  String serverEditorJumpRouteTooLong(int maxHops) {
    return 'The jump-host route exceeds $maxHops hops.';
  }

  @override
  String serverEditorJumpHostMissing(String serverId) {
    return 'Jump host “$serverId” is missing.';
  }

  @override
  String get serverEditorCancel => 'Cancel';

  @override
  String get serverEditorSave => 'Save';

  @override
  String get serverEditorTestDisclaimer =>
      'Testing authenticates without opening a shell or running the login script. A host key you approve here is trusted for the test only — the first real connection asks again.';

  @override
  String get serverEditorRequired => 'Required';

  @override
  String get serverEditorPortRange => '1–65535';

  @override
  String get serverEditorTestFailedSummary => 'Could not test the connection.';

  @override
  String serverEditorSaveFailed(String error) {
    return 'Could not save: $error';
  }

  @override
  String get serverEditorExcludeConfirmTitle => 'Exclude from sync?';

  @override
  String get serverEditorExcludeConfirmBody =>
      'If this server synced earlier, it is removed from the sync server and from your other devices, along with any credential that synced with it. This device keeps its copy.';

  @override
  String get serverEditorExcludeConfirmCancel => 'Cancel';

  @override
  String get serverEditorExcludeConfirmAction => 'Exclude';

  @override
  String get serverEditorCustomColour => 'Custom colour…';

  @override
  String serverEditorCustomColourValue(String hex) {
    return 'Custom colour ($hex)';
  }

  @override
  String get serverMarkPickerTitle => 'Server mark';

  @override
  String get serverMarkPickerIconsTab => 'Icons';

  @override
  String get serverMarkPickerEmojiTab => 'Emoji';

  @override
  String get serverMarkPickerImageTab => 'Image';

  @override
  String get serverMarkPickerCancel => 'Cancel';

  @override
  String get serverMarkPickerSearchHint =>
      'Search icons — try k8s, psql, prod…';

  @override
  String get serverMarkPickerNoMatch => 'No icon matches.';

  @override
  String get serverMarkPickerDefault => 'Default';

  @override
  String get serverMarkPickerEmojiHintMacOS =>
      'Press Control-Command-Space for the system emoji picker.';

  @override
  String get serverMarkPickerEmojiHintWindows =>
      'Press Windows-. for the system emoji picker.';

  @override
  String get serverMarkPickerEmojiHintLinux =>
      'Your desktop may offer an emoji picker with Control-Shift-E or Control-.';

  @override
  String get serverMarkPickerEmojiHintOther => 'Switch your keyboard to emoji.';

  @override
  String get serverMarkPickerAnyEmoji => 'Any emoji';

  @override
  String get serverMarkPickerOneEmoji => 'One emoji, please.';

  @override
  String get serverMarkPickerUse => 'Use';

  @override
  String get serverMarkPickerEmojiFontNote =>
      'An emoji is drawn with the system’s own emoji font, so a device without one shows a box — the icon chosen under Icons is what it falls back to there.';

  @override
  String get serverMarkPickerOpenFailed =>
      'That file could not be opened. Try another.';

  @override
  String get serverMarkPickerTooLarge =>
      'That file is too big to read. Crop or export it smaller first.';

  @override
  String get serverMarkPickerUndecodable =>
      'That file could not be read as an image.';

  @override
  String get serverMarkPickerEncodeFailed =>
      'That image could not be prepared. Try again, or pick another.';

  @override
  String get serverMarkPickerIncompressible =>
      'That image would not fit in a server record even at badge size. Try a simpler picture — a logo rather than a photograph.';

  @override
  String get serverMarkPickerNoImage => 'No image on this server yet.';

  @override
  String get serverMarkPickerHasImage => 'This server carries an image.';

  @override
  String get serverMarkPickerChooseImage => 'Choose image…';

  @override
  String get serverMarkPickerReplaceImage => 'Replace image…';

  @override
  String get serverMarkPickerRemoveImage => 'Remove image';

  @override
  String get serverMarkPickerImageFormats => 'PNG, JPEG, WebP or SVG';

  @override
  String get serverMarkPickerImageFormatsIos => 'PNG, JPEG or WebP';

  @override
  String serverMarkPickerImageExplanation(String formats, int side) {
    return '$formats. The image is cropped square, stored at $side pixels, and travels inside this server’s own settings — so it reaches your other devices with everything else about the server, and never arrives without it. Anything larger than a badge can show would only be paid for on every sync. A transparent image shows the server’s colour through it.';
  }

  @override
  String get serverColorPickerTitle => 'Custom colour';

  @override
  String get colorPickerHexLabel => 'Hex';

  @override
  String get colorPickerHexError => 'Six hex digits';

  @override
  String get colorPickerHue => 'Hue';

  @override
  String get colorPickerSaturation => 'Saturation';

  @override
  String get colorPickerBrightness => 'Brightness';

  @override
  String colorPickerDegrees(int degrees) {
    return '$degrees degrees';
  }

  @override
  String colorPickerPercent(int percent) {
    return '$percent percent';
  }

  @override
  String get serverColorPickerHint =>
      'Drawn as picked, with the mark kept legible on it in both themes. Devices running an older version show the nearest of the named colours instead.';

  @override
  String get colorPickerOpacity => 'Opacity';

  @override
  String get colorPickerHexErrorAlpha => 'Six or eight hex digits';

  @override
  String get colorPickerCancel => 'Cancel';

  @override
  String get colorPickerUse => 'Use colour';

  @override
  String get connectionLogCopied => 'Log copied';

  @override
  String get connectionLogCopyFailed => 'Could not copy the log';

  @override
  String get connectionTestSucceeded => 'Connection test succeeded';

  @override
  String get connectionTestFailed => 'Connection test failed';

  @override
  String get mainMenuTooltip => 'Main menu';

  @override
  String get toolbarMoreTooltip => 'More';

  @override
  String get inspectorLabel => 'Inspector';

  @override
  String get inspectorTabInfo => 'Info';

  @override
  String get inspectorTabTransfers => 'Transfers';

  @override
  String get inspectorTabAlerts => 'Alerts';

  @override
  String get alertsEmpty => 'All clear';

  @override
  String alertTransferFailed(String name) {
    return 'Couldn\'t transfer “$name”';
  }

  @override
  String alertDragOutFailed(String name) {
    return 'Couldn\'t drag “$name” out';
  }

  @override
  String alertDragOutPaused(String folder) {
    return 'Transfers are paused. Resume them, then drag it to $folder again.';
  }

  @override
  String alertDragOutPausedMidway(String folder) {
    return 'The download to $folder was paused, so it stopped.';
  }

  @override
  String alertDragOutRenamed(String folder) {
    return 'The drop in $folder asked for a different name than the folder\'s own.';
  }

  @override
  String get alertDragOutUnavailable =>
      'Remote items can\'t be downloaded right now.';

  @override
  String alertConflictsPending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count conflicts need a decision',
      one: '1 conflict needs a decision',
    );
    return '$_temp0';
  }

  @override
  String alertRestoredQueue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transfers from last session are paused',
      one: '1 transfer from last session is paused',
    );
    return '$_temp0';
  }

  @override
  String alertHostKeyChanged(String server) {
    return 'The host key for $server changed';
  }

  @override
  String alertConnectionFailed(String server) {
    return 'Couldn\'t connect to $server';
  }

  @override
  String alertLocalEdits(int count, String server) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count local edits on $server aren\'t uploaded',
      one: '1 local edit on $server isn\'t uploaded',
    );
    return '$_temp0';
  }

  @override
  String alertUpdateAvailable(String version) {
    return 'Poltergeist $version is available';
  }

  @override
  String get alertActionRetry => 'Retry';

  @override
  String get alertActionShow => 'Show';

  @override
  String get alertActionResolve => 'Resolve…';

  @override
  String get alertActionReview => 'Review…';

  @override
  String get alertActionViewRelease => 'View Release';

  @override
  String get alertActionDismiss => 'Dismiss';

  @override
  String get viewShowInspectorLabel => 'Show Inspector';

  @override
  String get viewHideInspectorLabel => 'Hide Inspector';

  @override
  String get viewShowAlertsLabel => 'Alerts';

  @override
  String get connectQuickConnectLabel => 'Connect…';

  @override
  String get connectShortLabel => 'Connect';

  @override
  String get connectDialogTitle => 'Connect to Server';

  @override
  String get syncShortLabel => 'Sync';

  @override
  String get selectionCopyToOtherPaneLabel => 'Copy to Other Pane';

  @override
  String get selectionMoveToOtherPaneLabel => 'Move to Other Pane';

  @override
  String get commandDisabledNeedsTwoPanes =>
      'Select items, and open a folder in the other pane';

  @override
  String get resizeSidebar => 'Resize sidebar';

  @override
  String get resizeInspector => 'Resize inspector';

  @override
  String splitterWidthPx(int value) {
    return '$value pixels';
  }

  @override
  String get headerFilterHint => 'Filter';

  @override
  String get headerTitleEmpty => 'No location';

  @override
  String get fileRevealMacLabel => 'Show in Finder';

  @override
  String get fileRevealLinuxLabel => 'Show in File Manager';

  @override
  String get fileRevealWindowsLabel => 'Show in Explorer';

  @override
  String get fileDownloadToLabel => 'Download To…';

  @override
  String get fileDownloadToDialogTitle => 'Download To';

  @override
  String get commandDisabledDownloadToRemoteOnly => 'Select items on a server';

  @override
  String get commandDisabledRevealLocalOnly => 'Select a local item';

  @override
  String get helpKeyboardShortcutsLabel => 'Keyboard Shortcuts';

  @override
  String get helpReleaseNotesLabel => 'Release Notes';

  @override
  String get helpReportIssueLabel => 'Report an Issue';

  @override
  String get helpShortcutsOtherGroup => 'Other';

  @override
  String get paneNewFolderName => 'untitled folder';

  @override
  String get paneNewFileName => 'untitled file';

  @override
  String paneCreateNamesExhausted(String name) {
    return 'No free name is left for \"$name\" in this folder.';
  }

  @override
  String activityTaskServerNotInCatalog(String server) {
    return 'The shared server \"$server\" is not in the synced server list on this device.';
  }

  @override
  String get fileNewFolderLabel => 'New Folder';

  @override
  String get fileNewFileLabel => 'New File';

  @override
  String get fileDuplicateLabel => 'Duplicate';

  @override
  String get fileCreateArchiveLabel => 'Create ZIP Archive';

  @override
  String get fileExtractArchiveLabel => 'Extract ZIP Archive';

  @override
  String get commandDisabledLocalArchive =>
      'Archives are available for local files only.';

  @override
  String get commandDisabledArchivesUnavailable =>
      'Archive support is unavailable.';

  @override
  String get commandDisabledSelectOneZip => 'Select one ZIP archive.';

  @override
  String get fileMoveToTrashLabel => 'Move to Trash';

  @override
  String get fileMoveToRecycleBinLabel => 'Move to Recycle Bin';

  @override
  String get fileDeleteRemoteLabel => 'Delete…';

  @override
  String get fileDeletePermanentlyLabel => 'Delete Immediately…';

  @override
  String get deleteDialogCounting => 'Counting items…';

  @override
  String deleteDialogPrepareFailed(String error) {
    return 'Couldn\'t prepare the delete: $error';
  }

  @override
  String deleteDialogDeleteCount(int count, String size, String location) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count items ($size) from $location?',
      one: 'Delete 1 item ($size) from $location?',
    );
    return '$_temp0';
  }

  @override
  String deleteDialogDeleteNames(String names, String location) {
    return 'Delete “$names” from $location?';
  }

  @override
  String deleteDialogDeleteUnquantified(String location) {
    return 'Delete the selected items from $location?';
  }

  @override
  String deleteDialogMoveCount(int count, String size, String location) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Move $count items ($size) to .poltergeist-trash/ on $location?',
      one: 'Move 1 item ($size) to .poltergeist-trash/ on $location?',
    );
    return '$_temp0';
  }

  @override
  String deleteDialogMoveNames(String names, String location) {
    return 'Move “$names” to .poltergeist-trash/ on $location?';
  }

  @override
  String deleteDialogMoveUnquantified(String location) {
    return 'Move the selected items to .poltergeist-trash/ on $location?';
  }

  @override
  String get deleteDialogIrreversible => 'This cannot be undone.';

  @override
  String get deleteDialogMoveWarning =>
      'Items are moved to .poltergeist-trash/ on the server.';

  @override
  String deleteDialogTrashUnavailable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'The Trash isn\'t available here, so these items will be deleted permanently.',
      one:
          'The Trash isn\'t available here, so this item will be deleted permanently.',
    );
    return '$_temp0';
  }

  @override
  String deleteDialogFlaggedExact(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Includes $count items with an undecodable name.',
      one: 'Includes 1 item with an undecodable name.',
    );
    return '$_temp0';
  }

  @override
  String get deleteDialogFlaggedMaybe =>
      'May include items with undecodable names.';

  @override
  String get deleteDialogServerTrashCheckbox =>
      'Move to .poltergeist-trash/ instead';

  @override
  String get deleteDialogServerTrashHelper =>
      'Trashed files stay on the server, readable by anything that can read the folder, until you purge them.';

  @override
  String deleteDialogConfirmDelete(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count Items',
      one: 'Delete',
    );
    return '$_temp0';
  }

  @override
  String deleteDialogConfirmMove(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Move $count Items',
      one: 'Move to Trash',
    );
    return '$_temp0';
  }

  @override
  String toolbarTooltipWithShortcut(String label, String shortcut) {
    return '$label  $shortcut';
  }

  @override
  String badgeCount(int count) {
    return '$count';
  }

  @override
  String get badgeCountOverflow => '99+';

  @override
  String syncPolicyOneWay(
    String destinationKind,
    String destination,
    String sourceKind,
    String source,
  ) {
    String _temp0 = intl.Intl.selectLogic(destinationKind, {
      'remote': 'remote',
      'other': 'local',
    });
    String _temp1 = intl.Intl.selectLogic(sourceKind, {
      'remote': 'remote',
      'other': 'local',
    });
    return 'Your $_temp0 folder “$destination” will be updated from your $_temp1 folder “$source”.';
  }

  @override
  String syncPolicyReplaceSizeDate(String source, String destination) {
    return 'Files that differ in size or modification date will be replaced with the version from “$source”, even when the copy in “$destination” is newer.';
  }

  @override
  String syncPolicyReplaceSize(String source) {
    return 'Files that differ in size will be replaced with the version from “$source”. Files of the same size are left alone, even when their dates differ.';
  }

  @override
  String syncPolicyReplaceChecksum(String source) {
    return 'Files whose size or contents differ will be replaced with the version from “$source”. Contents are compared by checksum, which reads every file of matching size on both sides.';
  }

  @override
  String get syncPolicySizeOnlyFallback =>
      'Modification dates proved unreliable for this pair, so only sizes are compared.';

  @override
  String syncPolicyBackupsInRoot(String trash, String destination) {
    return 'Previous versions of replaced files are kept in $trash inside “$destination”.';
  }

  @override
  String syncPolicyBackupsAt(String trashPath) {
    return 'Previous versions of replaced files are kept in $trashPath.';
  }

  @override
  String get syncPolicyBackupsNone =>
      'Replaced files are overwritten without a backup.';

  @override
  String syncPolicyDeleteTrash(
    String destination,
    String source,
    String trash,
  ) {
    return 'Files in “$destination” that aren’t in “$source” will be deleted (moved to $trash).';
  }

  @override
  String syncPolicyDeletePermanent(String destination, String source) {
    return 'Files in “$destination” that aren’t in “$source” will be deleted permanently.';
  }

  @override
  String get syncPolicyNoDeletes => 'No files will be deleted.';

  @override
  String syncPolicyBothWays(
    String leftKind,
    String left,
    String rightKind,
    String right,
  ) {
    String _temp0 = intl.Intl.selectLogic(leftKind, {
      'remote': 'remote',
      'other': 'local',
    });
    String _temp1 = intl.Intl.selectLogic(rightKind, {
      'remote': 'remote',
      'other': 'local',
    });
    return 'Your $_temp0 folder “$left” and your $_temp1 folder “$right” will each receive the files only the other one has.';
  }

  @override
  String get syncPolicyDifferSizeDate =>
      'Files count as different when their size or modification date differs.';

  @override
  String get syncPolicyDifferSize =>
      'Files count as different only when their size differs.';

  @override
  String get syncPolicyDifferChecksum =>
      'Files count as different when their size or checksum differs.';

  @override
  String get syncPolicyConflictAsk =>
      'Files that differ are held as conflicts for you to decide; nothing is replaced automatically.';

  @override
  String get syncPolicyConflictNewer =>
      'When a file differs, the newer copy replaces the older one.';

  @override
  String syncPolicyConflictKeep(String winner) {
    return 'When a file differs, the version from “$winner” replaces the other copy.';
  }

  @override
  String get syncPolicyConflictSkip => 'Files that differ are left alone.';

  @override
  String get syncPolicyBackupsEachSide =>
      'Previous versions of replaced files are kept in each side’s sync trash.';

  @override
  String get syncPolicyHiddenSkipped => 'Hidden files are left out.';

  @override
  String syncPolicyRulesSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Items matching $count rules are left out.',
      one: 'Items matching 1 rule are left out.',
    );
    return '$_temp0';
  }

  @override
  String get syncSheetTitle => 'Sync Files';

  @override
  String get syncSheetNewSavedTitle => 'New Saved Sync';

  @override
  String get syncSheetThisComputer => 'This computer';

  @override
  String get syncSheetServerFallback => 'Server';

  @override
  String get syncSheetChooseFolders => 'Choose Folders…';

  @override
  String syncSheetDirectionTooltip(String source, String destination) {
    return 'From $source to $destination. Click to reverse.';
  }

  @override
  String get syncSheetBothWaysTooltip => 'Both ways. Click to sync one way.';

  @override
  String syncSheetCompareSentence(String choice) {
    return 'Use the $choice to determine if a file has changed';
  }

  @override
  String get syncSheetCompareSizeDate => 'Size and Modification Date';

  @override
  String get syncSheetCompareSize => 'File Size';

  @override
  String get syncSheetCompareChecksum => 'Checksum';

  @override
  String get syncSheetDeleteOrphans => 'Delete orphaned destination files';

  @override
  String get syncSheetDeleteOrphansBothWays =>
      'Not available when syncing both ways';

  @override
  String get syncSheetDeleteToTrash => 'Move to trash (recommended)';

  @override
  String get syncSheetDeletePermanently => 'Delete permanently';

  @override
  String get syncSheetIncludeHidden => 'Include hidden files';

  @override
  String get syncSheetSkipRules => 'Skip items matching rules';

  @override
  String syncSheetRuleCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count rules',
      one: '1 rule',
      zero: 'No rules',
    );
    return '$_temp0';
  }

  @override
  String get syncSheetEditRules => 'Edit Rules…';

  @override
  String syncSheetTolerance(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: 'Modification date tolerance: $seconds seconds',
      one: 'Modification date tolerance: 1 second',
    );
    return '$_temp0';
  }

  @override
  String get syncSheetToleranceHourShift => 'ignoring exact 1-hour differences';

  @override
  String syncSheetToleranceOtherShifts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'plus $count custom time shifts',
      one: 'plus 1 custom time shift',
    );
    return '$_temp0';
  }

  @override
  String get syncSheetToleranceUnused => 'Modification dates aren’t compared';

  @override
  String get syncSheetTimeOffset => 'Time Offset…';

  @override
  String get syncSheetPlanLead => 'Here’s the plan:';

  @override
  String get syncSheetMore => 'More options';

  @override
  String get syncSheetBothWays => 'Sync Both Ways (Additive)';

  @override
  String get syncSheetAdvanced => 'Advanced…';

  @override
  String get syncSheetSimulate => 'Simulate';

  @override
  String get syncSheetSynchronize => 'Synchronize';

  @override
  String get syncSheetSimulateTooltip =>
      'Scan both sides and review the plan. Nothing changes until you run it.';

  @override
  String get syncSheetSynchronizeTooltip =>
      'Scan, then copy straight away when nothing would be replaced, deleted, or in conflict. Otherwise you review the plan first.';

  @override
  String get syncFavoriteNameTitle => 'Save as Favorite';

  @override
  String get syncRulesTitle => 'Skip Rules';

  @override
  String get syncRulesHint =>
      'One pattern per line, gitignore style: *.log, build/, /private.txt, !keep.log';

  @override
  String get syncRulesDefaultsTitle => 'Always skipped';

  @override
  String get syncRulesDone => 'Done';

  @override
  String get syncTimeOffsetTitle => 'Time Offset';

  @override
  String get syncTimeOffsetToleranceLabel => 'Tolerance in seconds';

  @override
  String get syncTimeOffsetToleranceHelp =>
      'Modification dates this close together count as the same.';

  @override
  String get syncTimeOffsetHourShift => 'Ignore exact 1-hour differences';

  @override
  String get syncTimeOffsetHourShiftHelp =>
      'For drives that store local time, such as FAT, across a daylight saving change.';

  @override
  String syncHoldBanner(String reasons) {
    return 'This plan $reasons — review before running.';
  }

  @override
  String syncHoldDeletes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'deletes $count files',
      one: 'deletes 1 file',
    );
    return '$_temp0';
  }

  @override
  String syncHoldEmptyFolders(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'removes $count empty folders',
      one: 'removes 1 empty folder',
    );
    return '$_temp0';
  }

  @override
  String syncHoldReplaces(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'replaces $count files',
      one: 'replaces 1 file',
    );
    return '$_temp0';
  }

  @override
  String syncHoldConflicts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'has $count conflicts',
      one: 'has 1 conflict',
    );
    return '$_temp0';
  }

  @override
  String get syncSectionCopy => 'Copy';

  @override
  String get syncSectionUpdate => 'Update';

  @override
  String get syncSectionDelete => 'Delete';

  @override
  String get syncSectionConflicts => 'Conflicts';

  @override
  String get syncSectionSkipped => 'Skipped';

  @override
  String syncSectionSemantics(String section, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$section, $_temp0';
  }

  @override
  String get syncColumnPath => 'Path';

  @override
  String get syncColumnReason => 'Reason';

  @override
  String syncRowSemantics(String path, String action, String reason) {
    return '$path: $action, $reason';
  }

  @override
  String syncRowActionCopy(String side) {
    return 'copy to “$side”';
  }

  @override
  String syncRowActionUpdate(String side) {
    return 'replace in “$side”';
  }

  @override
  String syncRowActionMakeDir(String side) {
    return 'create folder in “$side”';
  }

  @override
  String syncRowActionDelete(String side) {
    return 'delete from “$side”';
  }

  @override
  String get syncRowActionConflict => 'conflict';

  @override
  String get syncRowActionSkip => 'skip';

  @override
  String get syncRowToggleHint => 'Space includes or skips this row';

  @override
  String get deleteDialogNameSeparator => '”, “';

  @override
  String get paneColumnName => 'Name';

  @override
  String get paneColumnSize => 'Size';

  @override
  String get paneColumnModified => 'Date Modified';

  @override
  String get paneColumnSortedAscending => 'Sorted ascending';

  @override
  String get paneColumnSortedDescending => 'Sorted descending';

  @override
  String get paneColumnSortHint => 'Sort by this column';

  @override
  String paneSelectionSummary(int selected, int total) {
    return '$selected of $total selected';
  }

  @override
  String paneSelectionSummaryWithSize(String summary, String size) {
    return '$summary · $size';
  }

  @override
  String get paneAncestorMenuTooltip => 'Enclosing folders';

  @override
  String get viewToggleHiddenLabel => 'Show Hidden Files';

  @override
  String get selectionCopyPathLabel => 'Copy Path';

  @override
  String get tabCloseOthersLabel => 'Close Other Tabs';

  @override
  String get tabDuplicateLabel => 'Duplicate Tab';

  @override
  String get tabMoveToOtherPaneLabel => 'Move to Other Pane';

  @override
  String get tabCopyPathLabel => 'Copy Path';

  @override
  String get quickConnectAddressHostHint => 'host[:port]';

  @override
  String get viewKeepFoldersOnTopLabel => 'Keep Folders on Top';

  @override
  String get viewSortByLabel => 'Sort By';

  @override
  String get sidebarDevicesSection => 'Devices';

  @override
  String get sidebarFavoritesSection => 'Favorites';

  @override
  String get sidebarServersSection => 'Servers';

  @override
  String get sidebarFromSeanceAccount => 'From your Séance account';

  @override
  String get sidebarPinnedSection => 'Pinned';

  @override
  String get sidebarPinToTop => 'Pin to top';

  @override
  String get sidebarUnpin => 'Unpin';

  @override
  String get sidebarShowSection => 'Show';

  @override
  String get sidebarHideSection => 'Hide';

  @override
  String get sidebarFilterHint => 'Filter';

  @override
  String get sidebarNoMatches => 'No matches';

  @override
  String get sidebarAddMenu => 'Add';

  @override
  String get sidebarSettings => 'Settings';

  @override
  String get sidebarAddNewServer => 'New Server…';

  @override
  String get sidebarAddQuickConnect => 'Quick Connect…';

  @override
  String get sidebarAddCurrentFolder => 'Add Current Folder to Favorites';

  @override
  String get sidebarFavoritesAdd => 'Add Current Folder';

  @override
  String get sidebarServersAddNew => 'New Server';

  @override
  String get sidebarServersAddConnect => 'Quick Connect';

  @override
  String get sidebarSyncOff => 'Sync off';

  @override
  String get sidebarSyncOffTooltip => 'Set up Sync';

  @override
  String get sidebarSyncFailedChip => 'Sync failed';

  @override
  String get sidebarSyncNever => 'Not synced yet';

  @override
  String get sidebarSyncedJustNow => 'Synced · just now';

  @override
  String sidebarSyncedMinutes(int minutes) {
    return 'Synced · $minutes min';
  }

  @override
  String sidebarSyncedHours(int hours) {
    return 'Synced · $hours h';
  }

  @override
  String sidebarSyncedDays(int days) {
    return 'Synced · $days d';
  }

  @override
  String sidebarTabCount(int count) {
    return '×$count';
  }

  @override
  String get sidebarFavoritesAddStandard =>
      'Add Desktop, Documents, and Downloads';

  @override
  String get sidebarFavoritesEmpty => 'Drag folders here to keep them close.';

  @override
  String get sidebarServersEmpty =>
      'Quick Connect sessions show here. Save one to keep it in Favorites.';

  @override
  String get sidebarGroupEmpty => 'Drag favorites here';

  @override
  String get sidebarAddToFavorites => 'Add to Favorites';

  @override
  String get sidebarEject => 'Eject';

  @override
  String get sidebarSaveToFavorites => 'Save to Favorites…';

  @override
  String get sidebarSaveToFavoritesTitle => 'Save to Favorites';

  @override
  String get sidebarUnsavedSession => 'not saved';

  @override
  String get sidebarRenameServerTitle => 'Rename Server';

  @override
  String get sidebarDeleteServerTitle => 'Remove Server';

  @override
  String get viewFilterSidebarLabel => 'Filter Sidebar';

  @override
  String get viewUseCompactSidebarRowsLabel => 'Use Compact Sidebar Rows';

  @override
  String get viewUseComfortableSidebarRowsLabel =>
      'Use Comfortable Sidebar Rows';

  @override
  String sidebarEjectFailed(String name) {
    return 'Couldn\'t eject “$name”. Close anything using it and try again.';
  }

  @override
  String sidebarAlreadyFavorite(String label) {
    return '“$label” is already in Favorites.';
  }

  @override
  String sidebarDeleteServerBody(String label) {
    return 'Remove “$label” from Servers? This cannot be undone.';
  }

  @override
  String sidebarFreeSpaceSemantics(String size) {
    return '$size available';
  }

  @override
  String get compactHomeSearchHint => 'Search servers and folders';

  @override
  String get compactMoreOptions => 'More options';

  @override
  String get compactPaneLetterA => 'A';

  @override
  String get compactPaneLetterB => 'B';

  @override
  String compactPaneSwitchTooltip(String pane) {
    return 'Switch to $pane';
  }

  @override
  String compactPaneSwitcherSemantics(String shown) {
    return '$shown is showing';
  }

  @override
  String get compactFilterOpen => 'Filter this folder';

  @override
  String get compactFilterClose => 'Close filter';

  @override
  String compactRowDetails(String size, String date) {
    return '$size · $date';
  }

  @override
  String get compactRowFolder => 'Folder';

  @override
  String get compactRowLink => 'Link';

  @override
  String compactRowActions(String name) {
    return 'Actions for $name';
  }

  @override
  String compactSelectionCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count selected',
      one: '1 selected',
    );
    return '$_temp0';
  }

  @override
  String get compactSelectionClear => 'Clear selection';

  @override
  String compactActionCopyTo(String pane) {
    return 'Copy to $pane';
  }

  @override
  String compactActionMoveTo(String pane) {
    return 'Move to $pane';
  }

  @override
  String get compactActionDelete => 'Delete';

  @override
  String get compactActionMore => 'More';

  @override
  String compactTransfersPill(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transfers',
      one: '1 transfer',
    );
    return '$_temp0';
  }

  @override
  String compactTransfersPillProgress(String transfers, int percent) {
    return '$transfers · $percent%';
  }

  @override
  String get compactTransfersPillTooltip => 'Show transfers';

  @override
  String get compactSheetClose => 'Close inspector';

  @override
  String get compactCancel => 'Cancel';

  @override
  String get compactBreadcrumbsLabel => 'Folder path';

  @override
  String get compactLauncherHint =>
      'Connect to a server here, or go back to Home to pick a location.';

  @override
  String get compactGoToFolderTitle => 'Go to folder';

  @override
  String get compactGo => 'Go';

  @override
  String get compactDone => 'Done';

  @override
  String get sidebarThisDevice => 'This device';

  @override
  String get quickLookOverlayLabel => 'Quick Look';

  @override
  String get quickLookClose => 'Close Quick Look';

  @override
  String quickLookPosition(int index, int count) {
    return '$index of $count';
  }

  @override
  String get quickLookNoPreview => 'No preview for this kind of item.';

  @override
  String paneUnsavedSession(String endpoint) {
    return 'Not saved · $endpoint';
  }

  @override
  String get paneUnsavedDismiss => 'Dismiss';

  @override
  String get connectDialogServers => 'Servers';

  @override
  String get sidebarRowMenu => 'More actions';

  @override
  String get sidebarCompactRows => 'Compact rows';

  @override
  String get sidebarComfortableRows => 'Comfortable rows';

  @override
  String get compactHomeThisDeviceSubtitle => 'App storage';

  @override
  String compactHomeFreeSpace(String size) {
    return '$size free';
  }

  @override
  String compactHomeRemoteLocation(String server, String path) {
    return '$server · $path';
  }

  @override
  String compactHomeSyncRoute(String source, String destination) {
    return '$source → $destination';
  }

  @override
  String compactHomeServerState(String state, String endpoint) {
    return '$state · $endpoint';
  }

  @override
  String compactHomeTabsOpen(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tabs open',
      one: '1 tab open',
    );
    return '$_temp0';
  }

  @override
  String get compactHomeServersEmptyTitle => 'Connect to a server';

  @override
  String get compactHomeServersEmptyAccountBody =>
      'Servers on your Séance account appear here, with their status.';

  @override
  String get compactHomeServersEmptyBody =>
      'Quick Connect sessions appear here, with their status. Save one to keep it in Favorites.';

  @override
  String get compactHomeFavoritesEmptyTitle => 'Keep folders close';

  @override
  String get compactHomeFavoritesEmptyBody =>
      'Open a folder, then choose Add Current Folder to Favorites from its menu.';

  @override
  String compactAddedToFavorites(String label) {
    return 'Added “$label” to Favorites.';
  }

  @override
  String get goHomeLabel => 'Home';

  @override
  String get viewEnterFullScreenLabel => 'Enter Full Screen';

  @override
  String get viewExitFullScreenLabel => 'Exit Full Screen';

  @override
  String get commandDisabledNotConnected =>
      'Requires a tab connected to a server';

  @override
  String get commandDisabledNoQuickConnect =>
      'Requires an unsaved Quick Connect session';

  @override
  String connectDialogHighlightAnnouncement(String server, String detail) {
    return '$server, $detail. Press Return to open it.';
  }

  @override
  String get connectDialogHighlightCleared =>
      'No server highlighted. Press Return to connect to the address.';

  @override
  String alertCountSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alerts',
      one: '1 alert',
    );
    return '$_temp0';
  }

  @override
  String transferCountSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count unfinished transfers',
      one: '1 unfinished transfer',
    );
    return '$_temp0';
  }

  @override
  String fileRevealFailed(String name) {
    return '“$name” could not be shown in the file manager.';
  }

  @override
  String get appCheckForUpdatesLabel => 'Check for Updates…';

  @override
  String get appUpdateNoneFound =>
      'No newer version was found. If you’re offline, try again later.';

  @override
  String get appQuitLabel => 'Quit';

  @override
  String get deepLinkReviewTitle => 'Review connection link';

  @override
  String get deepLinkReviewBody =>
      'A link is asking Poltergeist to connect. Verify the endpoint before continuing.';

  @override
  String get deepLinkHostLabel => 'Host';

  @override
  String get deepLinkPortLabel => 'Port';

  @override
  String get deepLinkUsernameLabel => 'Username';

  @override
  String get deepLinkFolderLabel => 'Folder';

  @override
  String get deepLinkEmptyValue => 'Not specified';

  @override
  String get deepLinkConnect => 'Connect';

  @override
  String get deepLinkCancel => 'Cancel';

  @override
  String get deepLinkDiscardAll => 'Discard all remaining';

  @override
  String deepLinkRepeatedActivations(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'This endpoint was opened $count times.',
      two: 'This endpoint was opened twice.',
    );
    return '$_temp0';
  }

  @override
  String get deepLinkWaitingTitle => 'Waiting';

  @override
  String deepLinkAdditionalPending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count additional link activations pending',
      one: '1 additional link activation pending',
    );
    return '$_temp0';
  }

  @override
  String deepLinkEndpointSummary(String username, String host, int port) {
    return '$username@$host:$port';
  }

  @override
  String get deepLinkInternationalizedWarning =>
      'Internationalized hostname. Check every character.';

  @override
  String get deepLinkMixedScriptWarning =>
      'Mixed writing systems detected in this hostname.';

  @override
  String get deepLinkUnrecognizedScriptWarning =>
      'Unrecognized writing system in this hostname. Check every character.';

  @override
  String get deepLinkControlsRemovedWarning =>
      'Hidden direction or line-control characters were removed for display.';

  @override
  String get deepLinkFailureTitle => 'Link can’t be opened';

  @override
  String get deepLinkFailureUnsupported =>
      'This Poltergeist link does not name a supported action.';

  @override
  String get deepLinkFailureParameters =>
      'This Poltergeist link has invalid or unexpected parameters.';

  @override
  String get deepLinkFailurePort =>
      'This Poltergeist link must name a numeric port from 1 to 65535.';

  @override
  String get deepLinkFailurePath =>
      'This Poltergeist link contains an unsafe folder path.';

  @override
  String get deepLinkFailureServer =>
      'The linked server is not in your synchronized server catalog.';

  @override
  String get deepLinkFailureClose => 'Close';

  @override
  String get sidebarOpenTerminalInSeance => 'Open Terminal in Séance';

  @override
  String get commandDisabledNoRemoteServer =>
      'Requires a tab connected to a server';

  @override
  String get editorUndoLabel => 'Undo';

  @override
  String get editorRedoLabel => 'Redo';
}
