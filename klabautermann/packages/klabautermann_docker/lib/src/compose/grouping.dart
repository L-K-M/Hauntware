import 'package:meta/meta.dart';

import '../models/container.dart';
import 'labels.dart';
import 'ownership.dart';

/// A container's compose service (03 §7.16 STK-01, STK-02).
@immutable
final class ComposeService {
  const ComposeService({
    required this.name,
    required this.containers,
    this.image,
    this.dependsOn = const [],
    this.oneOff = false,
  });

  final String name;
  final List<ContainerSummary> containers;
  final String? image;

  /// Dependency service names from `com.docker.compose.depends_on`.
  final List<String> dependsOn;

  /// True when every container of the service is a `compose run` one-off
  /// (03 §7.16 STK-03: skipped by start and stop).
  final bool oneOff;

  /// The service state, from its first container.
  String? get state => containers.isEmpty ? null : containers.first.state;

  /// The service health, from its first container that reports one.
  HealthStatus? get health {
    for (final c in containers) {
      if (c.health != null) return c.health;
    }
    return null;
  }
}

/// A compose project: the containers sharing
/// `com.docker.compose.project` (03 §7.16 STK-01, STK-02).
@immutable
final class ComposeProject {
  const ComposeProject({
    required this.name,
    required this.services,
    required this.ownership,
    this.workingDir,
    this.configFiles = const [],
    this.environmentFiles = const [],
    this.configHash,
    this.version,
  });

  final String name;
  final List<ComposeService> services;
  final Ownership ownership;
  final String? workingDir;
  final List<String> configFiles;
  final List<String> environmentFiles;
  final String? configHash;
  final String? version;

  /// Every container of the project, services in first-seen order.
  List<ContainerSummary> get containers => [
    for (final s in services) ...s.containers,
  ];

  /// Services that are not one-off containers.
  List<ComposeService> get startable => [
    for (final s in services)
      if (!s.oneOff) s,
  ];

  /// `depends_on` order for start (03 §7.16 STK-03). A dependency cycle
  /// degrades to first-seen order for the affected services.
  List<ComposeService> get startOrder => _topological(startable);

  /// Reverse of [startOrder] for stop.
  List<ComposeService> get stopOrder => startOrder.reversed.toList();

  /// True when [startOrder] had to break a dependency cycle.
  bool get hasDependencyCycle {
    final ordered = startOrder;
    if (ordered.length != startable.length) return true;
    final seen = <String>{};
    for (final s in ordered) {
      for (final dep in s.dependsOn) {
        if (s.name != dep && !seen.contains(dep) && _has(startable, dep)) {
          return true;
        }
      }
      seen.add(s.name);
    }
    return false;
  }
}

/// The result of grouping a container list by compose project
/// (03 §7.16 STK-01).
@immutable
final class ComposeGrouping {
  const ComposeGrouping({required this.projects, required this.unmanaged});

  final List<ComposeProject> projects;

  /// Containers without a `com.docker.compose.project` label.
  final List<ContainerSummary> unmanaged;

  ComposeProject? project(String name) {
    for (final p in projects) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// Groups containers by compose project and service (03 §7.16 STK-01).
/// Containers without a project label land in [ComposeGrouping.unmanaged].
ComposeGrouping groupComposeProjects(List<ContainerSummary> containers) {
  final byProject = <String, List<(ComposeLabels, ContainerSummary)>>{};
  final unmanaged = <ContainerSummary>[];

  for (final c in containers) {
    final labels = ComposeLabels.fromContainerLabels(c.labels);
    if (labels == null) {
      unmanaged.add(c);
      continue;
    }
    byProject.putIfAbsent(labels.project, () => []).add((labels, c));
  }

  final projects = <ComposeProject>[];
  for (final e in byProject.entries) {
    final entries = e.value;
    final byService = <String, List<ContainerSummary>>{};
    final serviceLabels = <String, ComposeLabels>{};
    for (final (labels, c) in entries) {
      final service = labels.service ?? '';
      byService.putIfAbsent(service, () => []).add(c);
      serviceLabels.putIfAbsent(service, () => labels);
    }
    final services = <ComposeService>[];
    for (final se in byService.entries) {
      final labels = serviceLabels[se.key]!;
      services.add(
        ComposeService(
          name: se.key.isEmpty ? 'unknown' : se.key,
          containers: se.value,
          image: labels.image ?? se.value.first.image,
          dependsOn: labels.dependsOnServices,
          oneOff: se.value.every(
            (c) =>
                ComposeLabels.fromContainerLabels(c.labels)?.isOneOff ?? false,
          ),
        ),
      );
    }
    final first = entries.first.$1;
    projects.add(
      ComposeProject(
        name: e.key,
        services: services,
        ownership: Ownership.merge([
          for (final (_, c) in entries) detectOwnership(c.labels),
        ]),
        workingDir: first.workingDir,
        configFiles: first.configFiles,
        environmentFiles: first.environmentFiles,
        configHash: first.configHash,
        version: first.version,
      ),
    );
  }
  projects.sort((a, b) => a.name.compareTo(b.name));
  return ComposeGrouping(projects: projects, unmanaged: unmanaged);
}

List<ComposeService> _topological(List<ComposeService> services) {
  final byName = {for (final s in services) s.name: s};
  final visited = <String>{};
  final onStack = <String>{};
  final result = <ComposeService>[];

  void visit(ComposeService s) {
    if (visited.contains(s.name) || onStack.contains(s.name)) return;
    onStack.add(s.name);
    for (final dep in s.dependsOn) {
      final d = byName[dep];
      if (d != null) visit(d);
    }
    onStack.remove(s.name);
    visited.add(s.name);
    result.add(s);
  }

  for (final s in services) {
    visit(s);
  }
  return result;
}

bool _has(List<ComposeService> services, String name) =>
    services.any((s) => s.name == name);
