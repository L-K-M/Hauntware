import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../l10n/app_localizations.dart';

/// The characters of a container id the details show, as `docker ps`
/// does.
const kContainerIdShown = 12;

/// PRC-04 and PRC-05's facts from [detail] as label and value pairs, in
/// the order the details list them: what owns the process, then what it
/// uses. A fact the login user may not read says so; one the host did not
/// report reads [unknown].
List<(String, String)> processDetailFacts(
  AppLocalizations l10n,
  ProcessDetail detail, {
  required String unknown,
}) {
  final ProcessDetail(
    :attribution,
    :openFiles,
    :openFilesLimit,
    :processesLimit,
    :voluntarySwitches,
    :involuntarySwitches,
  ) = detail;
  String readable(String? value, {required bool denied}) =>
      value ?? (denied ? l10n.processesDetailNotReadable : unknown);
  String limit(int? value) =>
      value?.toString() ?? l10n.processesDetailUnlimited;

  final openFilesSoft = openFilesLimit?.soft;
  return [
    (l10n.processesDetailUnit, attribution.unit ?? l10n.processesDetailNoUnit),
    if (attribution.containerId case final id?)
      (
        l10n.processesDetailContainer,
        _container(l10n, attribution.runtime, id),
      ),
    (l10n.processesDetailCwd, readable(detail.cwd, denied: detail.cwdDenied)),
    (l10n.processesDetailThreads, detail.threads?.toString() ?? unknown),
    (
      l10n.processesDetailSwap,
      detail.swapKb == null
          ? unknown
          : ghostFormatBinarySize(detail.swapKb! * 1024),
    ),
    (
      l10n.processesDetailSwitches,
      voluntarySwitches == null || involuntarySwitches == null
          ? unknown
          : l10n.processesDetailSwitchesValue(
              voluntarySwitches,
              involuntarySwitches,
            ),
    ),
    (
      l10n.processesDetailOpenFiles,
      readable(
        openFiles == null
            ? null
            : openFilesSoft == null
            ? openFiles.toString()
            : l10n.processesDetailOpenFilesOf(openFiles, openFilesSoft),
        denied: detail.openFilesDenied,
      ),
    ),
    if (processesLimit != null)
      (l10n.processesDetailProcessLimit, limit(processesLimit.soft)),
  ];
}

/// [id] cut to [kContainerIdShown], after its runtime's name where known.
String _container(AppLocalizations l10n, ContainerRuntime? runtime, String id) {
  final shown = id.length > kContainerIdShown
      ? id.substring(0, kContainerIdShown)
      : id;
  return runtime == null
      ? shown
      : l10n.processesDetailContainerValue(runtime.name, shown);
}
