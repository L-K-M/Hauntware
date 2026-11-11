import 'dart:async';

import 'package:flutter/material.dart';

/// How an unlock attempt ended; the shared gate's copy of each app's own
/// outcome enum, so the screen needs no app or keystore import.
enum GhostAppLockUnlock { unlocked, failed, unavailable }

/// What [GhostAppLockGate] needs of an app's lock: its locked state, a
/// probe of the device prompt's availability, an unlock ask, and the
/// app's lifecycle. Each app adapts its own controller to this seam —
/// Klabautermann's `AppLockGateModel` over `AppLockController`, say.
abstract interface class GhostAppLockGateModel implements Listenable {
  /// Whether the lock screen covers the app.
  bool get locked;

  /// Asks the device again whether it can authenticate.
  Future<void> refreshAvailability();

  /// Asks for device authentication when locked.
  Future<GhostAppLockUnlock> unlock();

  /// Reports the app's lifecycle; the model locks after its own
  /// background timeout.
  void onLifecycle(AppLifecycleState state);
}

/// The lock screen's strings, in the app's own words and language.
final class GhostAppLockStrings {
  const GhostAppLockStrings({
    required this.title,
    required this.detail,
    required this.unlock,
    required this.failed,
    required this.unavailable,
  });

  /// What the locked app is called: "Klabautermann is locked".
  final String title;

  /// How to unlock, and what keeps running meanwhile.
  final String detail;

  /// The unlock button's label.
  final String unlock;

  /// The last attempt failed or was cancelled; try again.
  final String failed;

  /// The device has no passcode, PIN or biometrics to ask for.
  final String unavailable;
}

/// The app lock's screen (SAF-20) over everything [child] draws, the
/// routes and their dialogs included, while [model] is locked. The
/// covered app stays mounted, so links and views keep their state, but
/// it takes no pointer, focus or semantics and its tickers stop.
///
/// It asks for device authentication by itself once each time the lock
/// engages while the app is in the foreground, at launch included;
/// "Unlock" asks again. The gate also reports the app's lifecycle to
/// [model], which locks after its background timeout.
class GhostAppLockGate extends StatefulWidget {
  const GhostAppLockGate({
    super.key,
    required this.model,
    required this.strings,
    required this.child,
  });

  final GhostAppLockGateModel model;
  final GhostAppLockStrings strings;
  final Widget child;

  @override
  State<GhostAppLockGate> createState() => _GhostAppLockGateState();
}

class _GhostAppLockGateState extends State<GhostAppLockGate> {
  late final AppLifecycleListener _lifecycle;

  /// Whether this locked spell already asked by itself.
  bool _asked = false;

  /// The last attempt's outcome while still locked; null before one.
  GhostAppLockUnlock? _outcome;

  bool _unlocking = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    widget.model.addListener(_onLock);
    unawaited(widget.model.refreshAvailability());
    _askOnce();
  }

  @override
  void didUpdateWidget(GhostAppLockGate old) {
    super.didUpdateWidget(old);
    if (old.model == widget.model) return;
    old.model.removeListener(_onLock);
    widget.model.addListener(_onLock);
    // The asking is per model: a new one starts its own spell.
    _asked = false;
    _outcome = null;
    _askOnce();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.model.removeListener(_onLock);
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState state) {
    widget.model.onLifecycle(state);
    if (state == AppLifecycleState.resumed) _askOnce();
  }

  void _onLock() {
    if (!widget.model.locked) {
      _asked = false;
      _outcome = null;
    }
    if (mounted) setState(() {});
    _askOnce();
  }

  /// Asks after this frame, once per locked spell, and only while the app
  /// is in the foreground: the system prompt cannot show otherwise.
  void _askOnce() {
    if (_asked || !widget.model.locked) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    _asked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_unlock()));
  }

  Future<void> _unlock() async {
    if (_unlocking || !mounted) return;
    setState(() => _unlocking = true);
    final outcome = await widget.model.unlock();
    if (!mounted) return;
    setState(() {
      _unlocking = false;
      _outcome = outcome == GhostAppLockUnlock.unlocked ? null : outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.model.locked;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Nothing beneath reaches the user or takes input: no pointer,
        // no focus (so no keys), no semantics, no animation.
        IgnorePointer(
          ignoring: locked,
          child: ExcludeFocus(
            excluding: locked,
            child: ExcludeSemantics(
              excluding: locked,
              child: TickerMode(enabled: !locked, child: widget.child),
            ),
          ),
        ),
        if (locked)
          GhostAppLockScreen(
            strings: widget.strings,
            outcome: _outcome,
            unlocking: _unlocking,
            onUnlock: () => unawaited(_unlock()),
          ),
      ],
    );
  }
}

/// What the locked app shows: why, and "Unlock". [outcome] is the last
/// attempt's failure, if any.
class GhostAppLockScreen extends StatelessWidget {
  const GhostAppLockScreen({
    super.key,
    required this.strings,
    required this.outcome,
    required this.unlocking,
    required this.onUnlock,
  });

  final GhostAppLockStrings strings;
  final GhostAppLockUnlock? outcome;
  final bool unlocking;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = switch (outcome) {
      GhostAppLockUnlock.failed => strings.failed,
      GhostAppLockUnlock.unavailable => strings.unavailable,
      GhostAppLockUnlock.unlocked || null => null,
    };
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 16,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  Semantics(
                    header: true,
                    child: Text(
                      strings.title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  Text(
                    strings.detail,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (problem != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        problem,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton.icon(
                    autofocus: true,
                    onPressed: unlocking ? null : onUnlock,
                    icon: const Icon(Icons.fingerprint),
                    label: Text(strings.unlock),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
