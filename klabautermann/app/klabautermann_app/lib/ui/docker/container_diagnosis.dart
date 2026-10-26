import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart'
    show ContainerDetails, HealthStatus;

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// Restarts since the container was last started by hand from which its
/// restart policy reads as looping, though it runs now.
const _loopRestarts = 3;

/// What TRI-04 reads from a container's state, the most telling first.
enum ContainerDiagnosisKind {
  /// Killed by the OOM killer for going over its own memory limit.
  oomLimit,

  /// Killed by the OOM killer while the host ran out of memory; the
  /// container has no limit of its own.
  oomHost,

  /// Exit code 137 without the OOM flag: SIGKILL from a `docker kill`,
  /// a stop past its timeout, or another process.
  killed,

  /// Exit code 139: a segmentation fault.
  segfault,

  /// Exit code 126: the command exists but cannot run.
  notExecutable,

  /// Exit code 127: the command is not in the image.
  commandNotFound,

  /// The engine's own `State.Error`, such as an OCI runtime failure.
  runtimeError,

  /// Any other non-zero exit a stop does not leave.
  exitedWithError,

  /// Exit code 0 while the restart policy starts it again: its main
  /// process does not stay in the foreground.
  exitsAtOnce,

  /// The engine keeps starting it again.
  restartLoop,

  /// Its health check keeps failing.
  unhealthy,
}

/// One TRI-04 finding with what it names: a memory limit in bytes, an
/// exit code, a restart count or the engine's error. A failing health
/// check's streak shows in the overview and its output in Health checks,
/// where masked values can be revealed (03 §8.9).
@immutable
final class ContainerDiagnosis {
  const ContainerDiagnosis(this.kind, {this.number, this.text});

  final ContainerDiagnosisKind kind;
  final int? number;
  final String? text;

  @override
  bool operator ==(Object other) =>
      other is ContainerDiagnosis &&
      other.kind == kind &&
      other.number == number &&
      other.text == text;

  @override
  int get hashCode => Object.hash(kind, number, text);
}

/// The exit codes a stop leaves (SIGINT, SIGTERM), which say nothing
/// went wrong.
const _stopExitCodes = {130, 143};

/// TRI-04's heuristics over [container]'s state, restart count, memory
/// limit and health, without an LLM; empty when nothing reads as wrong.
List<ContainerDiagnosis> diagnoseContainer(ContainerDetails container) {
  final state = container.state;
  if (state == null) return const [];

  // A running container's exit code is the engine's 0, not its last.
  final exit = state.running ? null : state.exitCode;
  final error = state.error?.trim();
  final restarts = container.restartCount ?? 0;
  final memory = container.hostConfig?.memory ?? 0;
  final exitedAtOnce = state.restarting && exit == 0;

  return [
    if (state.oomKilled)
      memory > 0
          ? ContainerDiagnosis(ContainerDiagnosisKind.oomLimit, number: memory)
          : const ContainerDiagnosis(ContainerDiagnosisKind.oomHost),
    if (!state.oomKilled)
      ...switch (exit) {
        137 => const [ContainerDiagnosis(ContainerDiagnosisKind.killed)],
        139 => const [ContainerDiagnosis(ContainerDiagnosisKind.segfault)],
        126 => const [ContainerDiagnosis(ContainerDiagnosisKind.notExecutable)],
        127 => const [
          ContainerDiagnosis(ContainerDiagnosisKind.commandNotFound),
        ],
        final code? when code != 0 && !_stopExitCodes.contains(code) => [
          ContainerDiagnosis(
            ContainerDiagnosisKind.exitedWithError,
            number: code,
          ),
        ],
        _ => const <ContainerDiagnosis>[],
      },
    if (error != null && error.isNotEmpty)
      ContainerDiagnosis(ContainerDiagnosisKind.runtimeError, text: error),
    if (exitedAtOnce)
      const ContainerDiagnosis(ContainerDiagnosisKind.exitsAtOnce)
    else if (state.restarting || restarts >= _loopRestarts)
      ContainerDiagnosis(ContainerDiagnosisKind.restartLoop, number: restarts),
    if (state.health?.status == HealthStatus.unhealthy)
      const ContainerDiagnosis(ContainerDiagnosisKind.unhealthy),
  ];
}

/// One row of the details' Diagnosis section: the finding, what it
/// means and what it names.
class ContainerDiagnosisRow extends StatelessWidget {
  const ContainerDiagnosisRow({super.key, required this.diagnosis});

  final ContainerDiagnosis diagnosis;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final kind = diagnosis.kind;
    final number = diagnosis.number;
    final fact = switch (kind) {
      ContainerDiagnosisKind.oomLimit when number != null =>
        l10n.dockerDiagnosisMemoryLimit(ghostFormatBinarySize(number)),
      ContainerDiagnosisKind.exitedWithError when number != null =>
        l10n.dockerDiagnosisExitCode(number),
      ContainerDiagnosisKind.restartLoop => l10n.dockerDiagnosisRestarts(
        number ?? 0,
      ),
      _ => null,
    };
    final text = diagnosis.text;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(
            Icons.medical_information_outlined,
            size: 18,
            color: theme.colorScheme.error,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  l10n.dockerDiagnosisKind(kind.name),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  l10n.dockerDiagnosisWhy(kind.name),
                  style: theme.textTheme.bodySmall,
                ),
                if (fact != null) Text(fact, style: theme.textTheme.bodySmall),
                if (text != null)
                  SelectableText(
                    text,
                    maxLines: 4,
                    style: klabautermannMonoStyle.copyWith(
                      fontSize: theme.textTheme.bodySmall?.fontSize,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
