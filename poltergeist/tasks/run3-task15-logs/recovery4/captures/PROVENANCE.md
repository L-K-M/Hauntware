# Readable widget captures

Final source: 03f58198089c1020b54be3347df78d369ed14d95.
Flutter 3.47.2, framework d3b14c876900e553bc736ca19295fc09e3853e8e;
Dart 3.13.2. View: 1400x900, pixel ratio 1, light theme.

Harness: ../readable_capture_test.dart. Command from app/poltergeist_app:
`flutter test --reporter expanded /home/paseo/workspace/Poltergeist/tasks/run3-task15-logs/recovery4/readable_capture_test.dart`
Full final log: ../capture-final.log, exit 0.

Production PoltergeistApp/EngineSession/panes, scripted engine channels and
bookmarks. No socket, native window, installation, or real filesystem browse.
The harness alone loads fonts from the installed SDK's DevTools assets:
- Roboto/Roboto-Regular.ttf as Roboto.
- Roboto_Mono/RobotoMono-Regular.ttf as JetBrains Mono (explicit substitute).
- MaterialIcons-Regular.otf as MaterialIcons.
Base directory: /home/paseo/opt/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts.
Product code, theme, font assets, and dependencies are unchanged by this harness.

Inspected all five PNGs: readable names/paths/sizes, local and remote listings,
connecting state, reconnect banner, permission error and Retry; opaque shell
background and icon glyphs. Narrow toolbar labels/dates ellipsize. These are
widget evidence, not native typography/accessibility or install QA.

../captures-before holds f38c97f widget output before the toolbar fix. Its
remote-error.png is actually the unchanged remote listing: disabled Refresh
made the attempted error capture a no-op. Its remote-connecting.png catches
Connections before the pop animation finishes. Neither is evidence of its
filename's state. The final harness asserts route disappearance/spinner and
the permission diagnostic before capturing those states. Local/connected
before images document the disabled toolbar; final counterparts show it live.

Initial harness compile failure (modified instead of modifiedAt) is retained
in ../capture-compile-failure.log, not counted as a product regression.
The original tasks/run3-task15-captures/*.png remain Ahem/transparent geometry
captures. No readable pre-foundation/native before-state evidence exists here.
