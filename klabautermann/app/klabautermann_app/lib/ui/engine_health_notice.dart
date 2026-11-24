import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../controllers/engine_health.dart';
import '../l10n/app_localizations.dart';

/// Long enough to read the sentence.
const Duration _noticeDuration = Duration(seconds: 10);

/// The least time between two fault notices: an error that repeats, in a
/// timer say, is told once and again only after the user had quiet.
const Duration _faultNoticeInterval = Duration(minutes: 1);

/// Tells the user what [EngineHealth] hears (ENG-4, ENG-6): a toast when
/// the engine caught an error and went on, since what they just asked for
/// may not have happened, and a dialog when the engine stopped: that it
/// was restarted, or that nothing connects or updates any more when it
/// could not be. Mounted on the home route, which stays under every other
/// route. What it told is kept in [EngineHealth], since a restart
/// remounts it.
class EngineHealthNotice extends StatefulWidget {
  const EngineHealthNotice({
    super.key,
    required this.health,
    required this.child,
    this.now = DateTime.now,
  });

  /// Null where the app runs without one, as in most widget tests.
  final EngineHealth? health;
  final Widget child;

  /// A test seam for the fault notice's spacing.
  final DateTime Function() now;

  @override
  State<EngineHealthNotice> createState() => _EngineHealthNoticeState();
}

class _EngineHealthNoticeState extends State<EngineHealthNotice> {
  @override
  void initState() {
    super.initState();
    final health = widget.health;
    if (health == null) return;
    health.addListener(_onHealth);
    // One that stopped or faulted before this mounted is told after the
    // first frame, once the overlay exists.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onHealth());
  }

  @override
  void didUpdateWidget(EngineHealthNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.health, widget.health)) return;
    oldWidget.health?.removeListener(_onHealth);
    widget.health?.addListener(_onHealth);
  }

  @override
  void dispose() {
    widget.health?.removeListener(_onHealth);
    super.dispose();
  }

  void _onHealth() {
    final health = widget.health;
    if (!mounted || health == null) return;
    final l10n = AppLocalizations.of(context);

    if (health.takeFaultNotice(widget.now(), _faultNoticeInterval)) {
      showTopToast(
        Overlay.of(context, rootOverlay: true),
        message: l10n.engineFaultNotice,
        duration: _noticeDuration,
      );
    }

    final stopped = health.takeStopNotice();
    if (stopped == null) return;
    final restarted = stopped.recovery == EngineRecovery.restarted;
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            restarted ? l10n.engineRestartedTitle : l10n.engineStoppedTitle,
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  restarted ? l10n.engineRestartedBody : l10n.engineStoppedBody,
                ),
                if (stopped.error case final error?) ...[
                  const SizedBox(height: 12),
                  SelectableText(l10n.engineFailedDetail(error)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                MaterialLocalizations.of(dialogContext).okButtonLabel,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
