import 'package:flutter/material.dart';

/// A state in words beside an icon, read as one node; the icon adds a
/// shape, the text carries the meaning (A11Y-01). [detail] is the host's
/// or the engine's own output, never translated, cut to a few lines and
/// left out when empty.
class StateNotice extends StatelessWidget {
  const StateNotice({
    super.key,
    required this.icon,
    required this.text,
    this.detail,
  });

  final IconData icon;
  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final detail = this.detail;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(icon, size: 18, color: muted),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(text, style: theme.textTheme.bodyMedium),
                if (detail != null && detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
