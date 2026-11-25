import 'package:flutter/material.dart';

/// Opens an output bottom sheet over [context]: a drag-handled sheet that
/// starts at 0.6 of the height and drags between 0.3 and 1.
///
/// With [title] and [closeTooltip], a header row holds them above
/// [builder]'s body, which fills the rest of the sheet. Without them
/// [builder] fills the sheet itself, for a body that carries its own
/// scrolling title.
Future<void> showOutputSheet(
  BuildContext context, {
  required Widget Function(BuildContext, ScrollController) builder,
  String? title,
  String? closeTooltip,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    minChildSize: 0.3,
    maxChildSize: 1,
    builder: (context, scroll) => switch ((title, closeTooltip)) {
      (final header?, final tooltip?) => _OutputSheetFrame(
        title: header,
        closeTooltip: tooltip,
        builder: builder,
        scroll: scroll,
      ),
      _ => builder(context, scroll),
    },
  ),
);

/// [title] and its close button over [builder]'s body.
class _OutputSheetFrame extends StatelessWidget {
  const _OutputSheetFrame({
    required this.title,
    required this.closeTooltip,
    required this.builder,
    required this.scroll,
  });

  final String title;
  final String closeTooltip;
  final Widget Function(BuildContext, ScrollController) builder;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            IconButton(
              tooltip: closeTooltip,
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        Expanded(child: builder(context, scroll)),
      ],
    ),
  );
}
