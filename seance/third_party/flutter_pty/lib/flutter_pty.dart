import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_pty/src/flutter_pty_bindings_generated.dart';

const _libName = 'flutter_pty';

final DynamicLibrary _dylib = () {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

final _bindings = FlutterPtyBindings(_dylib);

final _init = () {
  return _bindings.Dart_InitializeApiDL(NativeApi.initializeApiDLData);
}();

void _ensureInitialized() {
  if (_init != 0) {
    throw StateError('Failed to initialize native bindings');
  }
}

/// Pty represents a process running in a pseudo-terminal.
///
/// To create a Pty, use [Pty.start].
class Pty {
  final String executable;

  final List<String> arguments;

  /// Spawns a process in a pseudo-terminal. The arguments have the same meaning
  /// as in [Process.start].
  /// [ackRead] indicates if the pty should wait for a call to [Pty.ackRead] before sending the next data.
  Pty.start(
    this.executable, {
    this.arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
    int rows = 25,
    int columns = 80,
    bool ackRead = false,
  }) {
    _ensureInitialized();

    final effectiveEnv = <String, String>{};

    effectiveEnv['TERM'] = 'xterm-256color';
    // Without this, tools like "vi" produce sequences that are not UTF-8 friendly
    effectiveEnv['LANG'] = 'en_US.UTF-8';

    const envValuesToCopy = {
      'LOGNAME',
      'USER',
      'DISPLAY',
      'LC_CTYPE',
      'HOME',
      'PATH'
    };

    for (var entry in Platform.environment.entries) {
      if (envValuesToCopy.contains(entry.key)) {
        effectiveEnv[entry.key] = entry.value;
      }
    }

    if (environment != null) {
      for (var entry in environment.entries) {
        effectiveEnv[entry.key] = entry.value;
      }
    }

    // Séance: all buffers below are borrowed by the native side only for
    // the duration of pty_create — on unix the child execs its fork-copy,
    // on Windows the buffers are copied into wide strings and consumed by
    // CreateProcessW before it returns — so the arena releases every
    // argv/envp/options allocation on both the success and failure path.
    Pointer<PtyHandle>? handle;
    try {
      handle = using((Arena arena) {
        // build argv
        final argv = arena<Pointer<Utf8>>(arguments.length + 2);
        argv.elementAt(0).value =
            executable.toNativeUtf8(allocator: arena);
        for (var i = 0; i < arguments.length; i++) {
          argv.elementAt(i + 1).value =
              arguments[i].toNativeUtf8(allocator: arena);
        }
        argv.elementAt(arguments.length + 1).value = nullptr;

        //build env
        final envp = arena<Pointer<Utf8>>(effectiveEnv.length + 1);
        for (var i = 0; i < effectiveEnv.length; i++) {
          final entry = effectiveEnv.entries.elementAt(i);
          envp.elementAt(i).value =
              '${entry.key}=${entry.value}'.toNativeUtf8(allocator: arena);
        }
        envp.elementAt(effectiveEnv.length).value = nullptr;

        final options = arena<PtyOptions>();
        options.ref.rows = rows;
        options.ref.cols = columns;
        options.ref.executable =
            executable.toNativeUtf8(allocator: arena).cast();
        options.ref.arguments = argv.cast();
        options.ref.environment = envp.cast();
        options.ref.stdout_port = _stdoutPort.sendPort.nativePort;
        options.ref.exit_port = _exitPort.sendPort.nativePort;
        options.ref.ackRead = ackRead;

        if (workingDirectory != null) {
          options.ref.working_directory =
              workingDirectory.toNativeUtf8(allocator: arena).cast();
        } else {
          options.ref.working_directory = nullptr;
        }

        return _bindings.pty_create(options);
      });

      final created = handle;
      if (created == null || created == nullptr) {
        throw StateError('Failed to create PTY: ${_getPtyError()}');
      }
      _handle = created;

      // Séance: cached eagerly — the native handle is released by [close]
      // but the pid must stay valid for callers enforcing kill policies.
      pid = _bindings.pty_getpid(created);

      _stdoutPort.listen(_onOutput);
      _exitPort.first.then(_onExitCode);
    } catch (_) {
      // A throwing constructor cannot hand back a usable Pty: release the
      // native half if one was created and close both ports so a failed
      // spawn does not leak them.
      final created = handle;
      if (created != null && created != nullptr) {
        _bindings.pty_close(created);
      }
      _stdoutPort.close();
      _exitPort.close();
      rethrow;
    }
  }

  final _stdoutPort = ReceivePort();

  final _exitPort = ReceivePort();

  final _exitCodeCompleter = Completer<int>();

  final _output = StreamController<Uint8List>();

  late final Pointer<PtyHandle> _handle;

  /// The output stream from the pseudo-terminal. Note that pseudo-terminals
  /// do not distinguish between stdout and stderr.
  ///
  /// Séance: it ends after the reader's last chunk, once every process
  /// holding the pty has closed it or [close] stopped the reader. It used
  /// to end when [exitCode] completed, dropping output still in flight.
  Stream<Uint8List> get output => _output.stream;

  /// A `Future` which completes with the exit code of the process
  /// when the process completes.
  ///
  /// The handling of exit codes is platform specific.
  ///
  /// On Linux and OS X a normal exit code will be a positive value in
  /// the range `[0..255]`. If the process was terminated due to a signal
  /// the exit code will be a negative value in the range `[-255..-1]`,
  /// where the absolute value of the exit code is the signal
  /// number. For example, if a process crashes due to a segmentation
  /// violation the exit code will be -11, as the signal SIGSEGV has the
  /// number 11.
  ///
  /// On Windows a process can report any 32-bit value as an exit
  /// code. When returning the exit code this exit code is turned into
  /// a signed value. Some special values are used to report
  /// termination due to some system event. E.g. if a process crashes
  /// due to an access violation the 32-bit exit code is `0xc0000005`,
  /// which will be returned as the negative number `-1073741819`. To
  /// get the original 32-bit value use `(0x100000000 + exitCode) &
  /// 0xffffffff`.
  ///
  /// There is no guarantee that [output] have finished reporting the buffered
  /// output of the process when the returned future completes.
  /// To be sure that all output is captured, wait for the done event on the
  /// streams.
  Future<int> get exitCode => _exitCodeCompleter.future;

  /// The process id of the process running in the pseudo-terminal.
  ///
  /// Séance: this is captured at spawn rather than read through the native
  /// handle each time, so it stays valid after [close] has released that
  /// handle — the kill watchdog a caller may run still needs it then.
  late final int pid;

  /// Whether [close] has run. Afterwards the native handle is gone, so
  /// every operation except [kill] is a no-op — [kill] does not touch the
  /// handle (the pid is cached) and stays usable.
  bool get isClosed => _closed;
  bool _closed = false;

  /// Séance: hangs up the pty and releases its native side — the master
  /// fd, the reader thread, the waitpid thread once the child is reaped,
  /// and the handle itself.
  ///
  /// Closing the master is what a terminal going away means: on unix the
  /// kernel hangs up the child's session (SIGHUP to its foreground process
  /// group), on Windows the pseudo console dies with it. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _bindings.pty_close(_handle);
  }

  /// Write data to the pseudo-terminal.
  void write(Uint8List data) {
    if (_closed) return;
    final buf = malloc<Int8>(data.length);
    buf.asTypedList(data.length).setAll(0, data);
    _bindings.pty_write(_handle, buf.cast(), data.length);
    malloc.free(buf);
  }

  /// Resize the pseudo-terminal.
  void resize(int rows, int cols) {
    if (_closed) return;
    _bindings.pty_resize(_handle, rows, cols);
  }

  /// Kill the process running in the pseudo-terminal.
  ///
  /// When possible, [signal] will be sent to the process. This includes
  /// Linux and OS X. The default signal is [ProcessSignal.sigterm]
  /// which will normally terminate the process.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    return Process.killPid(pid, signal);
  }

  /// indicates that a data chunk has been processed.
  /// This is needed when ackRead is set to true as the pty will wait for this signal to happen
  /// before any additional data is sent.
  void ackRead() {
    if (_closed) return;
    _bindings.pty_ack_read(_handle);
  }

  /// Séance: a chunk from the reader thread, or null once it has exited.
  void _onOutput(dynamic message) {
    if (message is Uint8List) {
      _output.add(message);
      return;
    }
    _stdoutPort.close();
    _output.close();
  }

  void _onExitCode(dynamic exitCode) {
    _exitPort.close();
    _exitCodeCompleter.complete(exitCode);
  }
}

String? _getPtyError() {
  final error = _bindings.pty_error();

  if (error == nullptr) {
    return null;
  }

  return error.cast<Utf8>().toDartString();
}
