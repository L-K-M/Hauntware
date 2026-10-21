import 'package:flutter/foundation.dart';

/// The device name's default (M5 plan Q6): what the host syslog line
/// names (SAF-13). It names the platform, never the device's hostname,
/// and stays in English, since it is written into every host's journal,
/// which an admin reads with every other device's lines.
String defaultDeviceName(TargetPlatform platform) {
  final name = switch (platform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.fuchsia => 'Fuchsia',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
  };
  return 'Klabautermann on $name';
}
