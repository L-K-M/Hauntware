/// Klabautermann's pure-Dart engine layer: the D18 engine isolate, its
/// plain-data protocol and the client the app composes over
/// (docs/design/klabautermann/03, sections 3.2 and 10.1).
library;

export 'src/engine/engine_client.dart';
export 'src/engine/protocol.dart';

// 03 §3.2: the app reaches seance_core, klabautermann_host and
// klabautermann_docker types only through this barrel, each behind an
// explicit `show` list that grows as its milestone wires the types in.
export 'package:klabautermann_host/klabautermann_host.dart'
    show Collector, CoreSnapshot, OverviewSnapshot;
// The app resolves `~/.ssh/config` for the FL-02 import with Séance's home
// rule, which also undoes a macOS sandbox's container `HOME`.
export 'package:seance_core/seance_core.dart' show expandHomePath;
