import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/ui/layout/pane_allocation.dart';

void main() {
  group('allocatePanes', () {
    test('keeps both panes at the compact boundary', () {
      final allocation = allocatePanes(
        width: 680,
        ratio: 0.5,
        secondPaneIntent: SecondPaneIntent.shown,
      );

      expect(allocation.stage, LayoutStage.compact);
      expect(allocation.showsSecondPane, isTrue);
      expect(allocation.primaryWidth, allocation.secondaryWidth);
      expect(allocation.totalWidth, 680);
    });

    test('auto-hides the second pane below the mobile boundary', () {
      final allocation = allocatePanes(
        width: 679,
        ratio: 0.5,
        secondPaneIntent: SecondPaneIntent.shown,
      );

      expect(allocation.stage, LayoutStage.mobile);
      expect(allocation.showsSecondPane, isFalse);
      expect(allocation.primaryWidth, 679);
      expect(allocation.secondaryWidth, 0);
    });

    test('preserves explicit second-pane hiding after regrowth', () {
      final allocation = allocatePanes(
        width: 1180,
        ratio: 0.5,
        secondPaneIntent: SecondPaneIntent.hidden,
      );

      expect(allocation.stage, LayoutStage.desktop);
      expect(allocation.showsSecondPane, isFalse);
    });

    test('clamps a restored ratio to usable pane widths', () {
      final allocation = allocatePanes(
        width: 720,
        ratio: 0.99,
        secondPaneIntent: SecondPaneIntent.shown,
      );

      expect(allocation.primaryWidth, 464);
      expect(allocation.secondaryWidth, 240);
      expect(allocation.totalWidth, 720);
    });
  });
}
