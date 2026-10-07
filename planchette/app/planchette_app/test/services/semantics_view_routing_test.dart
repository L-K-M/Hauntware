import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/semantics_view_routing.dart';

void main() {
  // Release builds, where no harness exists, are covered by
  // scripts/test-desktop-launch.py: asserts are always on here.
  testWidgets('ensureInitialized defers to a running binding', (tester) async {
    expect(PlanchetteBinding.ensureInitialized(), same(tester.binding));
  });
}
