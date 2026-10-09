import 'package:flutter/material.dart';

import '../services/app_lock.dart';
import '../services/settings_backend.dart';

/// The route and Settings window use the host's policy and availability.
class AppLockSettings extends StatefulWidget {
  const AppLockSettings({super.key, required this.backend});

  final SettingsBackend backend;

  @override
  State<AppLockSettings> createState() => _AppLockSettingsState();
}

class _AppLockSettingsState extends State<AppLockSettings> {
  bool _saving = false;
  String? _error;

  Future<void> _change(AppLockMode mode) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.backend.setAppLock(mode);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.backend,
    builder: (context, _) {
      if (widget.backend.appLockAvailability != AppLockAvailability.available) {
        return const SizedBox.shrink();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Require device authentication'),
            subtitle: const Text(
              'Use biometrics or your device passcode before reading saved '
              'secrets on launch and after 5 minutes in the background. '
              'Existing SSH sessions stay connected. Changing this setting '
              'requires authentication.',
            ),
            value: widget.backend.settings.appLock == AppLockMode.on,
            onChanged: _saving
                ? null
                : (value) => _change(value ? AppLockMode.on : AppLockMode.off),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );
}
