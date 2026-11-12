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
