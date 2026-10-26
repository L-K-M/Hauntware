import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show scaledGhostFileRowExtent;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/account_reads.dart';
import '../l10n/app_localizations.dart';
import 'sortable_table.dart';
import 'system_panel.dart' show PanelSection;

/// The accounts table's columns with the width each claims before text
/// scaling. The account's is the least it is given before the table drops
/// to the account, its UID and its root column.
enum AccountColumn {
  account(140),
  uid(72),
  root(160),
  groups(200),
  shell(160);

  const AccountColumn(this.width);

  final double width;
}

/// The unscaled width every column needs side by side.
final double _allColumnsWidth = AccountColumn.values.fold(
  0,
  (sum, column) => sum + column.width,
);

/// The most rows the table shows before it scrolls on its own.
const _visibleRows = 12;

/// ACC-01's words for why [account] can become root, or null.
String? rootEquivalenceText(AppLocalizations l10n, HostAccount account) {
  if (account.rootEquivalence.isEmpty) return null;
  return [
    for (final reason in RootEquivalence.values)
      if (account.rootEquivalence.contains(reason))
        l10n.systemAccountsRootReason(reason.name),
  ].join(', ');
}

/// The table's columns (ACC-01): the account, its UID and why it can
/// become root, and its groups and shell when [wide].
List<SortableTableColumn<HostAccount>> accountColumns(
  AppLocalizations l10n, {
  required bool wide,
}) => [
  SortableTableColumn<HostAccount>(
    id: AccountColumn.account.name,
    label: l10n.systemAccountsColumn,
    text: (account) => account.name,
    sortKey: (account) => account.name,
  ),
  SortableTableColumn<HostAccount>(
    id: AccountColumn.uid.name,
    label: l10n.systemAccountsUid,
    text: (account) => '${account.uid}',
    sortKey: (account) => account.uid,
    extent: FixedColumnExtent(AccountColumn.uid.width),
    alignment: CellAlignment.end,
  ),
  SortableTableColumn<HostAccount>(
    id: AccountColumn.root.name,
    label: l10n.systemAccountsRoot,
    text: (account) => rootEquivalenceText(l10n, account) ?? '',
    // Root-equivalent accounts first when sorted descending.
    sortKey: (account) => account.rootEquivalence.length,
    firstDirection: TableSortDirection.descending,
    extent: FixedColumnExtent(AccountColumn.root.width),
  ),
  if (wide) ...[
    SortableTableColumn<HostAccount>(
      id: AccountColumn.groups.name,
      label: l10n.systemAccountsGroups,
      text: (account) => account.groups.join(', '),
      sortKey: (account) => account.groups.join(','),
      extent: FixedColumnExtent(AccountColumn.groups.width),
    ),
    SortableTableColumn<HostAccount>(
      id: AccountColumn.shell.name,
      label: l10n.systemAccountsShell,
      text: (account) => account.shell,
      sortKey: (account) => account.shell,
      extent: FixedColumnExtent(AccountColumn.shell.width),
    ),
  ],
];

/// ACC-01 and ACC-02's section of the System tab: the server's accounts,
/// root-equivalent ones flagged and service accounts hidden until asked
/// for, and who is logged in. It reads when it shows and on request; a
/// server switch reads the new server's.
class AccountsSection extends StatefulWidget {
  const AccountsSection({
    super.key,
    required this.reads,
    required this.serverId,
    required this.tableId,
  });

  final AccountReads reads;
  final String serverId;

  /// The table's identity for its keys and remembered widths.
  final String tableId;

  @override
  State<AccountsSection> createState() => _AccountsSectionState();
}

class _AccountsSectionState extends State<AccountsSection> {
  AccountsReport? _report;
  bool _reading = false;
  bool _showSystem = false;
  int _ticket = 0;
  TableSort? _sort = TableSort(
    AccountColumn.root.name,
    TableSortDirection.descending,
  );

  @override
  void initState() {
    super.initState();
    _reading = true;
    unawaited(_read());
  }

  @override
  void didUpdateWidget(AccountsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.reads == widget.reads) {
      return;
    }
    _report = null;
    unawaited(_read());
  }

  Future<void> _read() async {
    // A read for an earlier server, or an earlier read, answers late.
    final ticket = ++_ticket;
    if (!_reading) setState(() => _reading = true);
    final report = await widget.reads.read(widget.serverId);
    if (!mounted || ticket != _ticket) return;
    setState(() {
      // A failed read again keeps the accounts last read for this server
      // in view under its failure.
      final kept = _report?.snapshot;
      _report = report.failure != null && kept != null
          ? AccountsReport(
              serverId: report.serverId,
              requestId: report.requestId,
              snapshot: kept,
              failure: report.failure,
            )
          : report;
      _reading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final report = _report;
    final snapshot = report?.snapshot;
    final failure = report?.failure;
    final accounts = [
      for (final account in snapshot?.accounts ?? const <HostAccount>[])
        if (_showSystem ||
            !account.isSystem ||
            account.rootEquivalence.isNotEmpty)
          account,
    ];
    final hidden = (snapshot?.accounts.length ?? 0) - accounts.length;

    return PanelSection(
      title: l10n.systemAccountsTitle,
      children: [
        if (failure != null)
          Text(l10n.systemAccountsFailed(failure.name))
        else if (snapshot == null && _reading)
          Text(l10n.systemAccountsReading),
        if (accounts.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              height:
                  (accounts.length.clamp(0, _visibleRows) + 1) *
                  scaledGhostFileRowExtent(context),
              child: SortableTable<HostAccount>(
                tableId: widget.tableId,
                columns: accountColumns(
                  l10n,
                  wide:
                      constraints.maxWidth >=
                      MediaQuery.textScalerOf(context).scale(_allColumnsWidth),
                ),
                rows: accounts,
                rowKey: (account) => account.name,
                sort: _sort,
                onSort: (sort) => setState(() => _sort = sort),
              ),
            ),
          ),
        if (snapshot != null && snapshot.notListed > 0)
          Text(l10n.systemAccountsNotListed(snapshot.notListed)),
        if (snapshot != null && (hidden > 0 || _showSystem))
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => setState(() => _showSystem = !_showSystem),
              child: Text(
                _showSystem
                    ? l10n.systemAccountsHideSystem
                    : l10n.systemAccountsShowSystem(hidden),
              ),
            ),
          ),
        if (snapshot != null) ..._sessions(l10n, snapshot),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            onPressed: _reading ? null : () => unawaited(_read()),
            child: Text(l10n.systemAccountsReadAgain),
          ),
        ),
      ],
    );
  }

  /// ACC-02's logins, or why there are none to show.
  List<Widget> _sessions(AppLocalizations l10n, AccountsSnapshot snapshot) {
    final theme = Theme.of(context);
    return [
      Semantics(
        header: true,
        child: Text(
          l10n.systemAccountsSessionsTitle,
          style: theme.textTheme.labelLarge,
        ),
      ),
      if (!snapshot.sessionsRead)
        Text(l10n.systemAccountsSessionsUnknown)
      else if (snapshot.sessions.isEmpty)
        Text(l10n.systemAccountsSessionsNone)
      else
        for (final session in snapshot.sessions)
          Text(
            session.from == null
                ? l10n.systemAccountsSessionLocal(
                    session.user,
                    session.line,
                    session.since.toLocal(),
                  )
                : l10n.systemAccountsSessionRemote(
                    session.user,
                    session.line,
                    session.from!,
                    session.since.toLocal(),
                  ),
          ),
    ];
  }
}
