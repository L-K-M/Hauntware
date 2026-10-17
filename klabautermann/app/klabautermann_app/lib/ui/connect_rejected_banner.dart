import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';

/// The most of the screen's height the banner takes, as the return
/// banner's share.
const double _bannerMaxShare = 0.2;

/// On a server's workspace or screen, why the engine could not connect it
/// ([MonitoringController.connectRejections], D61): it has no config to
/// dial with, and what the user can do about it. It shows until the next
/// connect of the server, which a new import sends.
class ConnectRejectedBanner extends StatelessWidget {
  const ConnectRejectedBanner({
    super.key,
    required this.monitoring,
    required this.serverId,
  });

  final MonitoringController monitoring;
  final String serverId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: monitoring.connectRejections,
      builder: (context, rejections, _) {
        final reason = rejections[serverId];
        if (reason == null) return const SizedBox.shrink();

        final l10n = AppLocalizations.of(context);
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        return Material(
          color: colors.errorContainer,
          // Past its share of the screen it scrolls, so at large text the
          // panel under it keeps its room on a short screen (A11Y-09).
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * _bannerMaxShare,
            ),
            child: SingleChildScrollView(
              primary: false,
              padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 8),
              child: Row(
                spacing: 12,
                children: [
                  Icon(Icons.link_off, color: colors.onErrorContainer),
                  Expanded(
                    // A state change, which screen readers hear (A11Y-15).
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        switch (reason) {
                          ConnectRejectedReason.noLoginName =>
                            l10n.connectRejectedNoLoginName,
                          ConnectRejectedReason.addressOnlyImport =>
                            l10n.connectRejectedAddressOnly,
                        },
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
