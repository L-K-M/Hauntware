import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

void main() {
  test('desktop menu panels remain rounded in square-corner themes', () {
    final base = ThemeData(platform: TargetPlatform.macOS);
    final square = GhostMenuTheme.apply(base, cornerScale: 0);
    expect(
      square.popupMenuTheme.shape,
      const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    );
    expect(
      square.menuTheme.style!.shape!.resolve({}),
      square.popupMenuTheme.shape,
    );

    final rounded = GhostMenuTheme.apply(base, cornerScale: 1.4);
    expect(
      rounded.popupMenuTheme.shape,
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(11.2)),
    );
    expect(
      GhostMenuTheme.apply(rounded).popupMenuTheme.shape,
      rounded.popupMenuTheme.shape,
    );
  });

  test('touch themes retain their own component sizing and corners', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      final base = ThemeData(platform: platform);
      expect(GhostMenuTheme.apply(base, cornerScale: 0), same(base));
    }
  });
}
