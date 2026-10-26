// TRI-04: what a container's state says went wrong, without an LLM.
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/docker/container_diagnosis.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

ContainerDetails _container({
  bool running = false,
  bool restarting = false,
  int? exitCode,
  bool oomKilled = false,
  String? error,
  int restartCount = 0,
  int? memory,
  ContainerDetailsHealth? health,
}) => ContainerDetails(
  id: 'c1',
  restartCount: restartCount,
  state: ContainerDetailsState(
    status: running ? 'running' : 'exited',
    running: running,
    restarting: restarting,
    exitCode: exitCode,
    oomKilled: oomKilled,
    error: error,
    health: health,
  ),
  hostConfig: ContainerHostConfig(memory: memory),
);

List<ContainerDiagnosisKind> _kinds(ContainerDetails container) => [
  for (final diagnosis in diagnoseContainer(container)) diagnosis.kind,
];

void main() {
  test('a running, healthy container or a stopped one reads as fine', () {
    expect(diagnoseContainer(_container(running: true, exitCode: 0)), isEmpty);
    expect(diagnoseContainer(_container(exitCode: 0)), isEmpty);
    expect(diagnoseContainer(_container(exitCode: 143)), isEmpty);
    expect(diagnoseContainer(_container(exitCode: 130)), isEmpty);
    expect(diagnoseContainer(const ContainerDetails(id: 'c1')), isEmpty);
  });

  test('an out-of-memory kill names its limit, or the host without one', () {
    expect(
      diagnoseContainer(
        _container(exitCode: 137, oomKilled: true, memory: 256 << 20),
      ),
      [
        const ContainerDiagnosis(
          ContainerDiagnosisKind.oomLimit,
          number: 256 << 20,
        ),
      ],
    );
    expect(_kinds(_container(exitCode: 137, oomKilled: true)), [
      ContainerDiagnosisKind.oomHost,
    ]);
  });

  test('exit codes read as a kill, a crash, a command problem or an error', () {
    expect(_kinds(_container(exitCode: 137)), [ContainerDiagnosisKind.killed]);
    expect(_kinds(_container(exitCode: 139)), [
      ContainerDiagnosisKind.segfault,
    ]);
    expect(_kinds(_container(exitCode: 126)), [
      ContainerDiagnosisKind.notExecutable,
    ]);
    expect(_kinds(_container(exitCode: 127)), [
      ContainerDiagnosisKind.commandNotFound,
    ]);
    expect(diagnoseContainer(_container(exitCode: 2)), [
      const ContainerDiagnosis(
        ContainerDiagnosisKind.exitedWithError,
        number: 2,
      ),
    ]);
    expect(
      _kinds(_container(running: true, exitCode: 1)),
      isEmpty,
      reason: "a running container's exit code is the engine's",
    );
  });

  test("the engine's error comes with its words", () {
    expect(
      diagnoseContainer(
        _container(
          exitCode: 127,
          error: 'exec: "app": executable file not found in \$PATH ',
        ),
      ),
      [
        const ContainerDiagnosis(ContainerDiagnosisKind.commandNotFound),
        const ContainerDiagnosis(
          ContainerDiagnosisKind.runtimeError,
          text: 'exec: "app": executable file not found in \$PATH',
        ),
      ],
    );
  });

  test('restarts read as a loop, or as a process that exits at once', () {
    expect(
      diagnoseContainer(
        _container(restarting: true, exitCode: 1, restartCount: 7),
      ),
      [
        const ContainerDiagnosis(
          ContainerDiagnosisKind.exitedWithError,
          number: 1,
        ),
        const ContainerDiagnosis(ContainerDiagnosisKind.restartLoop, number: 7),
      ],
    );
    expect(_kinds(_container(running: true, restartCount: 3)), [
      ContainerDiagnosisKind.restartLoop,
    ], reason: 'it runs now, but its policy has started it again and again');
    expect(_kinds(_container(running: true, restartCount: 2)), isEmpty);
    expect(_kinds(_container(restarting: true, exitCode: 0, restartCount: 9)), [
      ContainerDiagnosisKind.exitsAtOnce,
    ]);
  });

  test('a failing health check is named without its output', () {
    expect(
      diagnoseContainer(
        _container(
          running: true,
          health: ContainerDetailsHealth(
            status: HealthStatus.unhealthy,
            failingStreak: 4,
            log: [
              ContainerHealthCheck(
                exitCode: 1,
                output: MaskedValue.plain('old'),
              ),
              ContainerHealthCheck(
                exitCode: 1,
                output: MaskedValue.plain('connection refused\n'),
              ),
            ],
          ),
        ),
      ),
      [const ContainerDiagnosis(ContainerDiagnosisKind.unhealthy)],
    );
    expect(
      diagnoseContainer(
        _container(
          running: true,
          health: const ContainerDetailsHealth(status: HealthStatus.healthy),
        ),
      ),
      isEmpty,
    );
  });
}
