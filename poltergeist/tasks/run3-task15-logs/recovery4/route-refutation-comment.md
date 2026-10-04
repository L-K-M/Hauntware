The f38c97f route blocker is refuted, not applied. Flutter 3.47.2 [Route.isActive](https://github.com/flutter/flutter/blob/d3b14c876900e553bc736ca19295fc09e3853e8e/packages/flutter/lib/src/widgets/navigator.dart#L640-L643) reads entry presence. `handlePop` sets `popping` before the exit animation; `isPresent` excludes that state. It does not wait for disposal.

Runtime checks on the unchanged route code prove:
- Animated pop opens once while `isActive == false`, `navigator != null`, and animation status is reverse.
- PopScope veto and local history do not open.
- A covering route arriving during `maybePop` leaves Connections active but not current and does not open. Substituting `isCurrent` would break this case.

Proof: `tasks/run3-task15-logs/recovery4/route_lifecycle_test.dart`, `lifecycle.log`/exit0; committed normal/double-tap/veto/covered-route tests also pass. Latest 03f5819 review's held-path coverage and enablement comment are deferred under stabilization. The body records every disposition. No unresolved correctness finding or human request remains; exact-head CI34773511916, review34773510966, secret34773511923 pass.
