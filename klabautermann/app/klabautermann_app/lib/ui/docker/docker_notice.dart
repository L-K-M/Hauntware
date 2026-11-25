import 'package:flutter/material.dart';

import '../panel_kit.dart';

/// A state in words beside an icon, read as one node, with the engine's
/// own [detail] under it, never translated, and an optional [action];
/// the Docker tab's views share it.
class DockerNotice extends StatelessWidget {
  const DockerNotice({
    super.key,
    required this.icon,
    required this.text,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String text;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      PanelNotice.state(icon: icon, text: text, detail: detail),
      ?action,
    ],
  );
}
