import 'package:meta/meta.dart';

import '../docker_parse_result.dart';

/// `ps` options [DockerClient.containerTop] asks the daemon for on Linux
/// (03 §7.12 CTR-10): every process with its owner, CPU share, resident
/// memory and age, and the command line last, where the daemon keeps the
/// spaces that `ps` printed. The daemon keeps the rows whose PID is in
/// the container.
const kContainerTopPsArgs = '-eo pid,user,pcpu,rss,etime,args';

/// `GET /containers/{id}/top` (03 §7.12 CTR-10): the columns `ps` (or
/// on Windows the daemon) named, and one row of cells per process. A
/// command line in a row can carry secrets: callers mask it before it
/// crosses.
@immutable
final class ContainerTop {
  ContainerTop({
    required List<String> titles,
    required List<List<String>> processes,
  }) : titles = List.unmodifiable(titles),
       processes = List.unmodifiable([
         for (final row in processes) List<String>.unmodifiable(row),
       ]);

  final List<String> titles;

  /// Each row has one cell per title.
  final List<List<String>> processes;
}

/// Parses a container top response; never throws. A row whose cells do
/// not match the titles is skipped.
DockerParseResult<ContainerTop> parseContainerTop(Object? decoded) {
  final warnings = <String>[];
  if (decoded is! Map) {
    warnings.add('container top is not a JSON object');
    return DockerParseResult(ContainerTop(titles: [], processes: []), warnings);
  }

  final rawTitles = decoded['Titles'];
  final titles = [
    if (rawTitles is List)
      for (final title in rawTitles)
        if (title is String) title,
  ];
  if (rawTitles is! List || titles.length != rawTitles.length) {
    warnings.add('container top titles are not a list of strings');
    return DockerParseResult(ContainerTop(titles: [], processes: []), warnings);
  }

  final processes = <List<String>>[];
  final rawProcesses = decoded['Processes'];
  for (final row in rawProcesses is List ? rawProcesses : const []) {
    final cells = [
      if (row is List)
        for (final cell in row)
          if (cell is String) cell,
    ];
    if (row is! List || cells.length != titles.length) {
      warnings.add('container top row skipped');
      continue;
    }
    processes.add(cells);
  }
  return DockerParseResult(
    ContainerTop(titles: titles, processes: processes),
    warnings,
  );
}
