/// Save cleanup is opt-in: spaces and missing final breaks can be intentional.
enum TrailingWhitespacePolicy { preserve, trim }

enum FinalNewlinePolicy { preserve, ensure }

final class TextSaveOptions {
  const TextSaveOptions({
    this.trailingWhitespace = TrailingWhitespacePolicy.preserve,
    this.finalNewline = FinalNewlinePolicy.preserve,
  });

  final TrailingWhitespacePolicy trailingWhitespace;
  final FinalNewlinePolicy finalNewline;

  @override
  bool operator ==(Object other) =>
      other is TextSaveOptions &&
      other.trailingWhitespace == trailingWhitespace &&
      other.finalNewline == finalNewline;

  @override
  int get hashCode => Object.hash(trailingWhitespace, finalNewline);
}
