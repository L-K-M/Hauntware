import 'package:meta/meta.dart';

import '../masking.dart';

/// The `com.docker.compose.*` label keys (03 §7.16 STK-01, from compose
/// `pkg/api/labels.go`).
abstract final class ComposeLabelKeys {
  static const String project = 'com.docker.compose.project';
  static const String service = 'com.docker.compose.service';
  static const String containerNumber = 'com.docker.compose.container-number';
  static const String oneoff = 'com.docker.compose.oneoff';
  static const String projectConfigFiles =
      'com.docker.compose.project.config_files';
  static const String projectWorkingDir =
      'com.docker.compose.project.working_dir';
  static const String projectEnvironmentFile =
      'com.docker.compose.project.environment_file';
  static const String configHash = 'com.docker.compose.config-hash';
  static const String image = 'com.docker.compose.image';
  static const String dependsOn = 'com.docker.compose.depends_on';
  static const String version = 'com.docker.compose.version';
}

/// The compose labels of one container (03 §7.16 STK-01). Only the
/// compose keys are kept: the label map itself may hold secrets and is
/// never copied here (03 §8.9).
@immutable
final class ComposeLabels {
  const ComposeLabels({
    required this.project,
    this.service,
    this.containerNumber,
    this.workingDir,
    this.configFiles = const [],
    this.environmentFiles = const [],
    this.configHash,
    this.image,
    this.oneoff,
    this.dependsOn = const [],
    this.version,
  });

  final String project;
  final String? service;
  final String? containerNumber;
  final String? workingDir;
  final List<String> configFiles;
  final List<String> environmentFiles;
  final String? configHash;
  final String? image;
  final bool? oneoff;

  /// `service:condition:required` entries from the label; the service
  /// name is the part before the first colon.
  final List<String> dependsOn;
  final String? version;

  /// True for a `docker compose run` one-off container (03 §7.16 STK-03).
  bool get isOneOff => oneoff ?? false;

  /// The dependency service names in the recorded order (03 §7.16
  /// STK-03).
  List<String> get dependsOnServices => [
    for (final d in dependsOn)
      if (d.split(':').first.trim().isNotEmpty) d.split(':').first.trim(),
  ];

  /// Builds the compose view from a container's labels, or null when the
  /// project label is absent or masked away. Values are read through
  /// [MaskedValue.display]; compose keys never match the secret pattern
  /// of 03 §8.9, so this sees the real text.
  static ComposeLabels? fromContainerLabels(Map<String, MaskedValue> labels) {
    String? value(String key) {
      final v = labels[key];
      if (v == null || v.isMasked) return null;
      final text = v.display;
      return text.isEmpty ? null : text;
    }

    final project = value(ComposeLabelKeys.project);
    if (project == null) return null;

    bool? oneoff;
    final oneoffRaw = value(ComposeLabelKeys.oneoff);
    if (oneoffRaw != null) {
      oneoff = switch (oneoffRaw.toLowerCase()) {
        'true' => true,
        'false' => false,
        _ => null,
      };
    }

    return ComposeLabels(
      project: project,
      service: value(ComposeLabelKeys.service),
      containerNumber: value(ComposeLabelKeys.containerNumber),
      workingDir: value(ComposeLabelKeys.projectWorkingDir),
      configFiles: _splitList(value(ComposeLabelKeys.projectConfigFiles)),
      environmentFiles: _splitList(
        value(ComposeLabelKeys.projectEnvironmentFile),
      ),
      configHash: value(ComposeLabelKeys.configHash),
      image: value(ComposeLabelKeys.image),
      oneoff: oneoff,
      dependsOn: _splitList(value(ComposeLabelKeys.dependsOn)),
      version: value(ComposeLabelKeys.version),
    );
  }
}

List<String> _splitList(String? raw) {
  if (raw == null) return const <String>[];
  return [
    for (final part in raw.split(','))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}
