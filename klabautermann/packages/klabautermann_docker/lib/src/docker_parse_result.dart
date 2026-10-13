/// Parse outcome for host input: a value plus warnings. Parsers in this
/// package never throw on untrusted input; anything odd but usable lands
/// in [warnings] (the `ParseResult<T>` convention of 03 §3.3, named
/// apart from `klabautermann_host`'s type so one library can import both).
final class DockerParseResult<T> {
  const DockerParseResult(this.value, [this.warnings = const <String>[]]);

  final T value;
  final List<String> warnings;
}
