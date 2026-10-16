/// The replay engine for the app's frame-timing test (spike S5 part 2, 03
/// §11.4): a stand-in engine isolate that serves the committed host
/// fixtures through the real parsers and sample pipeline. Test support
/// only; the app's `lib/` never imports it (its architecture contract
/// test checks).
library;

export 'src/replay/host_fixtures.dart'
    show HostFixture, loadHostFixtures, loadJournalRows;
export 'src/replay/replay_engine.dart' show ReplayPlan, replayEngine;
