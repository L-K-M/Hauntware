// The update check's Klabautermann pins (c3 §shells): the suite's shared
// release repository and Klabautermann's own user agent. The app's
// update_check_controller_test pins the Android asset to the manifest.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  test('checks the shared suite release as Klabautermann', () {
    expect(klabautermannUpdateRepo, hauntwareUpdateRepo);
    expect(klabautermannUpdateUserAgent, 'Klabautermann-update-check');
  });
}
