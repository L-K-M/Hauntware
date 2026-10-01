import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class ReleaseProcessResult {
  final int exitCode;
  final String standardOutput;
  final String standardError;
  final List<int> binaryOutput;

  const ReleaseProcessResult({
    required this.exitCode,
    this.standardOutput = '',
    this.standardError = '',
    this.binaryOutput = const [],
  });
}

enum ReleaseLaunchStatus { remainedRunning, exited }

final class ReleaseLaunchResult {
  final ReleaseLaunchStatus status;
  final int? exitCode;

  const ReleaseLaunchResult.remainedRunning()
    : status = ReleaseLaunchStatus.remainedRunning,
      exitCode = null;

  const ReleaseLaunchResult.exited(this.exitCode)
    : status = ReleaseLaunchStatus.exited;
}

/// Keeps process and stream mechanics below release-domain adapters.
abstract interface class ReleaseProcessRunner {
  Future<ReleaseProcessResult> run(
    String executable,
    List<String> arguments, {
    Directory? workingDirectory,
  });

  Future<ReleaseProcessResult> runToFile(
    String executable,
    List<String> arguments, {
    required File output,
    Directory? workingDirectory,
  });

  Future<ReleaseLaunchResult> observeLaunch(
    String executable,
    List<String> arguments, {
    required Duration observation,
    Directory? workingDirectory,
  });
}

final class IoReleaseProcessRunner implements ReleaseProcessRunner {
  const IoReleaseProcessRunner();

  @override
  Future<ReleaseProcessResult> run(
    String executable,
    List<String> arguments, {
    Directory? workingDirectory,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory?.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    return ReleaseProcessResult(
      exitCode: result.exitCode,
      standardOutput: result.stdout.toString(),
      standardError: result.stderr.toString(),
    );
  }

  @override
  Future<ReleaseProcessResult> runToFile(
    String executable,
    List<String> arguments, {
    required File output,
    Directory? workingDirectory,
  }) async {
    output.parent.createSync(recursive: true);
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory?.path,
    );
    final error = process.stderr.transform(utf8.decoder).join();
    await process.stdout.pipe(output.openWrite());
    final processExitCode = await process.exitCode;

    return ReleaseProcessResult(
      exitCode: processExitCode,
      standardError: await error,
    );
  }

  @override
  Future<ReleaseLaunchResult> observeLaunch(
    String executable,
    List<String> arguments, {
    required Duration observation,
    Directory? workingDirectory,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory?.path,
    );
    final outputDrain = process.stdout.drain<void>();
    final errorDrain = process.stderr.drain<void>();
    final observationFinished = Object();
    final first = await Future.any<Object>([
      process.exitCode.then<Object>((code) => code),
      Future<Object>.delayed(observation, () => observationFinished),
    ]);
    if (first is int) {
      await Future.wait([outputDrain, errorDrain]);
      return ReleaseLaunchResult.exited(first);
    }

    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await Future.wait([outputDrain, errorDrain]);

    return const ReleaseLaunchResult.remainedRunning();
  }
}
