/// Shared desktop window-state lifecycle for the Planchette family: restore
/// the remembered frame and presentation flags, track them while the app
/// runs, and run the intercepted close path. Hosts own their persistence
/// format and their product-specific hooks through the adapter interfaces.
library;

export 'src/adapters.dart';
export 'src/geometry.dart';
export 'src/lifecycle.dart';
export 'src/snapshot.dart';
