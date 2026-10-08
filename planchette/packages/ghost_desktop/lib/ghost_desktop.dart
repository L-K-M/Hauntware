/// Shared desktop window-state lifecycle for the Planchette family: restore
/// the remembered frame and presentation flags, track them while the app
/// runs, and run the intercepted close path. Hosts own their persistence
/// format and their product-specific hooks through the adapter interfaces.
/// Hosts with extra windows also route misaddressed accessibility actions
/// to their views through [semanticsActionView]. On macOS,
/// [MacosToolbarBandChannel] reports the toolbar band a header draws under.
/// A desktop Settings window on a second engine keeps in step with the app
/// through [GhostSettingsWindowHost] and [GhostSettingsWindowClient].
library;

export 'src/adapters.dart';
export 'src/geometry.dart';
export 'src/lifecycle.dart';
export 'src/macos_toolbar_band.dart';
export 'src/semantics_routing.dart';
export 'src/settings_link.dart';
export 'src/snapshot.dart';
