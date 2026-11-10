/// The apps' shared update-check session, over `seance_core`'s
/// [UpdateChecker] and `ghost_apk_update`'s installer. Each app injects
/// its release repository, user agent and Android release asset; the
/// banners and strings stay app-owned.
library;

export 'src/update_check_controller.dart';
export 'src/update_check_settings.dart';
