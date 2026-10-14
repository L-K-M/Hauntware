import 'dart:async';

import 'package:klabautermann_app/services/ssh_config_source.dart';

/// The tests' [SshConfigSource]: answers every read with [result], or
/// holds reads open on [gate] when one is set, and counts them. No file
/// system.
final class FakeSshConfigSource implements SshConfigSource {
  FakeSshConfigSource(this.result);

  /// A source whose config holds [text].
  FakeSshConfigSource.text(String text) : this(SshConfigText(text));

  /// A source whose config cannot be read for [failure].
  FakeSshConfigSource.failing(SshConfigReadFailure failure)
    : this(SshConfigUnavailable(failure));

  SshConfigRead result;
  int reads = 0;

  /// When set, reads wait for it to complete, so a test can observe an
  /// import mid-flight.
  Completer<void>? gate;

  @override
  Future<SshConfigRead> read() async {
    reads++;
    await gate?.future;
    return result;
  }
}
