import 'package:flutter/material.dart';

/// A heading over its [children], stretched to the width: the heading
/// is a node of its own that screen readers announce as a heading.
class TitledGroup extends StatelessWidget {
  const TitledGroup({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      Semantics(
        container: true,
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
      ...children,
    ],
  );
}

/// A section's state in words beside an icon, read as one node; the icon
/// adds a shape, the text carries the meaning (A11Y-01).
class PanelNotice extends StatelessWidget {
  const PanelNotice({
    super.key,
    required this.icon,
    required this.text,
    this.detail,
    this.iconSize = 18,
    this.live = false,
    this.mutedDetail = true,
    this.omitEmptyDetail = false,
  });

  /// A read's state: as [PanelNotice], but an empty [detail] is left out
  /// rather than drawn blank.
  const PanelNotice.state({
    super.key,
    required this.icon,
    required this.text,
    this.detail,
  }) : iconSize = 18,
       live = false,
       mutedDetail = true,
       omitEmptyDetail = true;

  final IconData icon;
  final String text;

  /// The host's error output, cut to a few lines.
  final String? detail;

  /// The icon's size: 18 px, or 20 for a panel's standing notice.
  final double iconSize;

  /// Whether changes are announced as they happen, as a panel's standing
  /// notices are; otherwise the row reads as one node.
  final bool live;

  /// Whether [detail] is drawn muted; a panel's own notices use the plain
  /// body-small style.
  final bool mutedDetail;

  /// Drops an empty [detail] instead of drawing nothing for it, as the
  /// reads' notices do.
  final bool omitEmptyDetail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final detail = this.detail;
    final shown = omitEmptyDetail
        ? detail != null && detail.isNotEmpty
        : detail != null;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Icon(icon, size: iconSize, color: muted),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(text, style: theme.textTheme.bodyMedium),
              if (shown)
                Text(
                  detail,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: mutedDetail
                      ? theme.textTheme.bodySmall?.copyWith(color: muted)
                      : theme.textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ],
    );
    return live
        ? Semantics(liveRegion: true, child: row)
        : MergeSemantics(child: row);
  }
}

/// A titled group of facts on its own surface, here and in the Overview
/// tab. Its title is a heading for screen readers, and its children may
/// hold ink (the pseudo filter).
class PanelSection extends StatelessWidget {
  const PanelSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Semantics(
              header: true,
              child: Text(title, style: theme.textTheme.titleSmall),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// The panel width at which a panel's wide layout starts: the tables add
/// their extra columns and the cards sit side by side. It grows with the
/// text scale, as the tables' columns do, so larger text takes the narrow
/// layout before a table would scroll sideways.
const double kPanelWideWidth = 600;

/// Whether [constraints] are at least [kPanelWideWidth] after the text
/// scaler has had its say.
bool panelIsWide(BuildContext context, BoxConstraints constraints) =>
    constraints.maxWidth >=
    MediaQuery.textScalerOf(context).scale(kPanelWideWidth);

/// The share of its height a panel's header takes before it scrolls, so
/// large text never pushes the table or log view out of sight.
const double kPanelHeaderShare = 0.4;

/// [header] over [body]: the header scrolls within [kPanelHeaderShare] of
/// the height when it would take more, then a 12 px gap, then the body in
/// what is left. Pass [headerMaxHeight] when the caller's constraints
/// include padding this widget does not apply itself, and the share is of
/// the caller's height rather than this one's.
class HeadedPanelBody extends StatelessWidget {
  const HeadedPanelBody({
    super.key,
    required this.header,
    required this.body,
    this.headerScroll,
    this.headerMaxHeight,
  });

  final Widget header;
  final Widget body;
  final ScrollController? headerScroll;
  final double? headerMaxHeight;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight:
                headerMaxHeight ?? constraints.maxHeight * kPanelHeaderShare,
          ),
          child: SingleChildScrollView(controller: headerScroll, child: header),
        ),
        const SizedBox(height: 12),
        Expanded(child: body),
      ],
    ),
  );
}

/// A listenable that never notifies: what a panel listens to while none of
/// its readings can age, so the clock stops until one can.
final Listenable kSilentListenable = Listenable.merge(const []);
