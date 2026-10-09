# Reconnect widget evidence

Source: 994a2c05bce9ea2ea2af6c37434fa5fdfb55040c, PR95.
Flutter3.47.2 / framework d3b14c876900e553bc736ca19295fc09e3853e8e;
Dart3.13.2. Light theme, 1400x900, pixel ratio1.
Command and full output: ../capture-final.command, ../capture-final.log;
explicit exit0. Harness: ../readable_capture_test.dart.

Production PoltergeistApp/EngineSession/panes, scripted engine/bookmark lanes.
No socket, native window, installed application or real filesystem browsing.
Only the harness loads installed DevTools Roboto and MaterialIcons; Roboto
Mono substitutes for JetBrains Mono. Product fonts/theme/dependencies unchanged.
Font root: /home/paseo/opt/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts.

Seven inspected captures:
- local-both-panes: readable ordinary listings, live Parent/Refresh.
- remote-connecting: settled route pop, pending channel, connecting message.
- remote-connected: bound listing, live Parent/Refresh.
- remote-connection-lost: cached rows visible below banner, disabled verbs.
- healing-listing-pending: connected status with held listing; same banner,
  cache and disabled verbs, no loading/error overlay.
- healing-failed: one dim layer and localized Retry/Cancel, cache retained.
- healing-complete: explicit reopened binding accepts healed-index.html;
  banner absent, Parent/Refresh restored. Harness verifies old close exactly1.

Banner overlap was a real visual defect: cached first text y40 was hidden by
banner bottom y98 in the widget runtime red. The repaired layout reserves
banner space. TextButton color animation is settled before the loss capture;
its callback is asserted null, not inferred from color alone.

Read all five recovery4 captures and their provenance, plus its three toolbar
runtime reds. The local/remote toolbar repair remains intact. Its loss capture
also illustrates the now-repaired action and covered-row gaps. Original Ahem
captures, mislabeled preliminary error/connecting captures, and harness-only
compile/tap failures remain preserved with their original limitations. These
images do not establish native typography, accessibility, installation, or
real-SFTP QA. Toolbar/date ellipsis is unchanged and outside this repair.
