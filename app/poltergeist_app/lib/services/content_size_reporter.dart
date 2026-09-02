import 'package:flutter/material.dart';

final class ContentSizeReporter extends StatelessWidget {
  const ContentSizeReporter({
    required this.child,
    required this.onSize,
    super.key,
  });

  final Widget child;
  final ValueChanged<Size> onSize;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          WidgetsBinding.instance.addPostFrameCallback((_) => onSize(size));
        }
        return child;
      },
    );
  }
}
