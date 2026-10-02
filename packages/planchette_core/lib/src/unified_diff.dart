import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

/// Context lines each hunk shows around its changes, the unified-diff default.
const int unifiedDiffContext = 3;

/// The largest diff [unifiedDiff] will produce, in characters. A change set
/// whose diff would exceed it is refused, never trimmed to look smaller and
/// never reported as unchanged.
const int unifiedDiffOutputLimit = 1 << 20;

/// How long the diff isolate may run before [boundedUnifiedDiff] kills it.
/// Every path inside [unifiedDiff] is bounded, so this is a backstop for a
/// host whose scheduler starves the worker, not the primary limit.
const Duration unifiedDiffBudget = Duration(seconds: 2);

/// Combined lines in the two changed middles beyond which the diff stops
/// trying to be minimal and replaces the whole middle in one hunk. Bounds the
/// O(n×m) matching table to a fixed size.
const int _minimalDiffLineLimit = 2000;

/// What a comparison found.
enum UnifiedDiffStatus {
  /// The texts are equal; there is nothing to show.
  identical,

  /// The texts differ; [UnifiedDiffResult.text] holds the unified diff.
  differs,

  /// The diff would exceed the output limit. The texts do differ; showing
  /// them as equal would be a lie.
  tooLarge,

  /// The worker did not finish within its budget.
  timedOut,

  /// The worker failed; the diff was not computed.
  failed,
}

final class UnifiedDiffResult {
  const UnifiedDiffResult(this.status, [this.text = '', this.detail = '']);

  final UnifiedDiffStatus status;

  /// The unified diff, set only for [UnifiedDiffStatus.differs].
  final String text;

  /// A failure detail, set for [UnifiedDiffStatus.failed].
  final String detail;
}

/// Compares two texts as a unified diff, bounded in time and output.
///
/// Common leading and trailing lines are trimmed cheaply, so a lone edit in a
/// large file costs O(lines). The remaining middle is matched minimally while
/// it fits [_minimalDiffLineLimit] lines; a larger middle, or any middle the
/// matcher cannot resolve within the limit, is emitted as one hunk that
/// replaces the whole middle — a correct diff, just not a minimal one. A diff
/// that would outgrow [outputLimit] is refused as
/// [UnifiedDiffStatus.tooLarge].
UnifiedDiffResult unifiedDiff(
  String oldText,
  String newText, {
  String oldLabel = 'old file',
  String newLabel = 'new file',
  int context = unifiedDiffContext,
  int outputLimit = unifiedDiffOutputLimit,
}) {
  if (oldText == newText) {
    return const UnifiedDiffResult(UnifiedDiffStatus.identical);
  }

  final oldLines = _linesWithEndings(oldText);
  final newLines = _linesWithEndings(newText);

  // Trim lines both texts open with and close with. Trailing lines only count
  // while they are not the text's last line with a terminator on one side and
  // none on the other; comparing terminator-baked strings covers that.
  var start = 0;
  while (start < oldLines.length &&
      start < newLines.length &&
      oldLines[start] == newLines[start]) {
    start++;
  }
  var oldEnd = oldLines.length;
  var newEnd = newLines.length;
  while (oldEnd > start &&
      newEnd > start &&
      oldLines[oldEnd - 1] == newLines[newEnd - 1]) {
    oldEnd--;
    newEnd--;
  }

  final oldMiddle = oldLines.sublist(start, oldEnd);
  final newMiddle = newLines.sublist(start, newEnd);

  // One op list over the middles: 0 equal, 1 delete, 2 add. Equal ops pair
  // one old and one new line; the anchors reference them by index.
  final kinds = <int>[];
  final olds = <int>[];
  final news = <int>[];
  if (oldMiddle.isEmpty) {
    for (var j = 0; j < newMiddle.length; j++) {
      kinds.add(2);
      olds.add(-1);
      news.add(j);
    }
  } else if (newMiddle.isEmpty) {
    for (var i = 0; i < oldMiddle.length; i++) {
      kinds.add(1);
      olds.add(i);
      news.add(-1);
    }
  } else if (oldMiddle.length + newMiddle.length > _minimalDiffLineLimit) {
    _appendWholeMiddleReplacement(kinds, olds, news, oldMiddle, newMiddle);
  } else {
    _appendMinimalOps(kinds, olds, news, oldMiddle, newMiddle);
  }

  return _format(
    oldLines: oldLines,
    newLines: newLines,
    kinds: kinds,
    olds: olds,
    news: news,
    start: start,
    oldLabel: oldLabel,
    newLabel: newLabel,
    context: context,
    outputLimit: outputLimit,
  );
}

/// Lines with their terminators baked in, so equality sees a missing final
/// newline. The last line carries no terminator when the text ends without
/// one; an empty text has no lines.
List<String> _linesWithEndings(String text) {
  if (text.isEmpty) return const [];
  final parts = text.split('\n');
  final lines = [
    for (var i = 0; i < parts.length - 1; i++) '${parts[i]}\n',
    // A final piece without its terminator is the text's last line; a
    // trailing '\n' leaves an empty final piece that is no line at all.
    if (parts.last.isNotEmpty) parts.last,
  ];
  return lines;
}

void _appendWholeMiddleReplacement(
  List<int> kinds,
  List<int> olds,
  List<int> news,
  List<String> oldMiddle,
  List<String> newMiddle,
) {
  for (var i = 0; i < oldMiddle.length; i++) {
    kinds.add(1);
    olds.add(i);
    news.add(-1);
  }
  for (var j = 0; j < newMiddle.length; j++) {
    kinds.add(2);
    olds.add(-1);
    news.add(j);
  }
}

/// Minimal insert/delete script by longest common subsequence. The middles
/// fit [_minimalDiffLineLimit] lines combined, so the (n+1)×(m+1) table is
/// bounded whatever the input size.
void _appendMinimalOps(
  List<int> kinds,
  List<int> olds,
  List<int> news,
  List<String> oldMiddle,
  List<String> newMiddle,
) {
  final m = oldMiddle.length;
  final n = newMiddle.length;
  final width = n + 1;
  final table = Uint16List((m + 1) * width);

  // table[i * width + j]: LCS length of oldMiddle[i..] and newMiddle[j..].
  for (var i = m - 1; i >= 0; i--) {
    final oldLine = oldMiddle[i];
    for (var j = n - 1; j >= 0; j--) {
      table[i * width + j] = oldLine == newMiddle[j]
          ? table[(i + 1) * width + j + 1] + 1
          : _max(table[(i + 1) * width + j], table[i * width + j + 1]);
    }
  }

  var i = 0;
  var j = 0;
  while (i < m && j < n) {
    if (oldMiddle[i] == newMiddle[j]) {
      kinds.add(0);
      olds.add(i);
      news.add(j);
      i++;
      j++;
    } else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) {
      kinds.add(1);
      olds.add(i);
      news.add(-1);
      i++;
    } else {
      kinds.add(2);
      olds.add(-1);
      news.add(j);
      j++;
    }
  }
  while (i < m) {
    kinds.add(1);
    olds.add(i++);
    news.add(-1);
  }
  while (j < n) {
    kinds.add(2);
    olds.add(-1);
    news.add(j++);
  }
}

int _max(int a, int b) => a > b ? a : b;

/// One line of the finished edit script: its kind (0 equal, 1 delete,
/// 2 add), where it sits in the old and new texts (-1 when absent), and the
/// line itself with its terminator baked in.
typedef _Annotated = (int kind, int oldIndex, int newIndex, String line);

UnifiedDiffResult _format({
  required List<String> oldLines,
  required List<String> newLines,
  required List<int> kinds,
  required List<int> olds,
  required List<int> news,
  required int start,
  required String oldLabel,
  required String newLabel,
  required int context,
  required int outputLimit,
}) {
  final oldEnd = start + olds.where((index) => index >= 0).length;
  final newEnd = start + news.where((index) => index >= 0).length;

  // The whole document as one annotated line list: equal prefix, the middles'
  // ops, then the equal suffix. Indexes are absolute; a suffix line's new
  // index sits at the same offset from newEnd as its old index from oldEnd.
  final annotated = <_Annotated>[];
  for (var i = 0; i < start; i++) {
    annotated.add((0, i, i, oldLines[i]));
  }
  for (var op = 0; op < kinds.length; op++) {
    final kind = kinds[op];
    final oldIndex = olds[op];
    final newIndex = news[op];
    annotated.add((
      kind,
      oldIndex < 0 ? -1 : start + oldIndex,
      newIndex < 0 ? -1 : start + newIndex,
      oldIndex >= 0 ? oldLines[start + oldIndex] : newLines[start + newIndex],
    ));
  }
  for (var i = oldEnd; i < oldLines.length; i++) {
    annotated.add((0, i, newEnd + (i - oldEnd), oldLines[i]));
  }

  final out = StringBuffer();
  var wroteHeader = false;
  String rangeLabel(int first, int count) => switch (count) {
    0 => '${first + 1},0',
    1 => '${first + 1}',
    _ => '${first + 1},$count',
  };

  // Hunks: unions of the [change - context, change + context] windows. Two
  // changes share a hunk while at most 2*context equal lines separate them.
  var change = 0;
  final changes = [
    for (var i = 0; i < annotated.length; i++)
      if (annotated[i].$1 != 0) i,
  ];
  while (change < changes.length) {
    var last = change;
    while (last + 1 < changes.length &&
        changes[last + 1] - changes[last] <= 2 * context + 1) {
      last++;
    }
    final from = (changes[change] - context).clamp(0, annotated.length);
    final to = (changes[last] + context + 1).clamp(0, annotated.length);

    var oldFirst = -1;
    var oldCount = 0;
    var newFirst = -1;
    var newCount = 0;
    for (var i = from; i < to; i++) {
      final (kind, oldIndex, newIndex, _) = annotated[i];
      if (kind != 2) {
        oldCount++;
        if (oldFirst < 0) oldFirst = oldIndex;
      }
      if (kind != 1) {
        newCount++;
        if (newFirst < 0) newFirst = newIndex;
      }
    }

    if (!wroteHeader) {
      out
        ..write('--- ')
        ..writeln(oldLabel)
        ..write('+++ ')
        ..writeln(newLabel);
      wroteHeader = true;
    }
    out
      ..write('@@ -')
      ..write(rangeLabel(oldFirst, oldCount))
      ..write(' +')
      ..write(rangeLabel(newFirst, newCount))
      ..writeln(' @@');
    for (var i = from; i < to; i++) {
      final (kind, _, _, line) = annotated[i];
      out
        ..write(
          kind == 0
              ? ' '
              : kind == 1
              ? '-'
              : '+',
        )
        ..writeln(_content(line));
      // Only a text's last line can lack a terminator; git marks it so the
      // patch reproduces the missing newline exactly.
      if (!line.endsWith('\n')) {
        out.writeln('\\ No newline at end of file');
      }
    }
    if (out.length > outputLimit) {
      return const UnifiedDiffResult(UnifiedDiffStatus.tooLarge);
    }
    change = last + 1;
  }

  // Different texts always leave a change; reaching here without one means
  // the only difference was in trimmed terminators, handled above.
  if (!wroteHeader) return const UnifiedDiffResult(UnifiedDiffStatus.identical);
  return UnifiedDiffResult(UnifiedDiffStatus.differs, out.toString());
}

String _content(String line) =>
    line.endsWith('\n') ? line.substring(0, line.length - 1) : line;

final class _DiffRequest {
  const _DiffRequest(
    this.reply,
    this.oldText,
    this.newText,
    this.oldLabel,
    this.newLabel,
    this.context,
    this.outputLimit,
  );

  final SendPort reply;
  final String oldText;
  final String newText;
  final String oldLabel;
  final String newLabel;
  final int context;
  final int outputLimit;
}

final class _DiffReply {
  const _DiffReply(this.result, this.error);
  final UnifiedDiffResult? result;
  final String? error;
}

/// Computes [unifiedDiff] in a worker isolate under [budget], for texts too
/// large to match on the UI isolate. The worker is one-shot: it is killed
/// once it answers or its budget runs out, so a wedged comparison can never
/// hang the caller, and the worst outcome is an honest
/// [UnifiedDiffStatus.timedOut].
Future<UnifiedDiffResult> boundedUnifiedDiff(
  String oldText,
  String newText, {
  String oldLabel = 'old file',
  String newLabel = 'new file',
  int context = unifiedDiffContext,
  int outputLimit = unifiedDiffOutputLimit,
  Duration budget = unifiedDiffBudget,
}) {
  final inbox = RawReceivePort();
  final completer = Completer<UnifiedDiffResult>();
  Isolate? worker;
  var done = false;

  void finish(UnifiedDiffResult result) {
    if (done) return;
    done = true;
    inbox.close();
    worker?.kill(priority: Isolate.immediate);
    completer.complete(result);
  }

  inbox.handler = (Object? message) {
    final reply = message! as _DiffReply;
    final error = reply.error;
    finish(
      error == null
          ? reply.result!
          : UnifiedDiffResult(
              UnifiedDiffStatus.failed,
              '',
              'The comparison failed: $error',
            ),
    );
  };

  final deadline = Timer(budget, () {
    finish(const UnifiedDiffResult(UnifiedDiffStatus.timedOut));
  });

  Isolate.spawn(
        _diffWorkerMain,
        _DiffRequest(
          inbox.sendPort,
          oldText,
          newText,
          oldLabel,
          newLabel,
          context,
          outputLimit,
        ),
        debugName: 'unified diff',
      )
      .then((spawned) {
        // The deadline may have fired while the spawn was still starting.
        if (done) {
          spawned.kill(priority: Isolate.immediate);
        } else {
          worker = spawned;
        }
      })
      .catchError((Object error) {
        finish(
          UnifiedDiffResult(
            UnifiedDiffStatus.failed,
            '',
            'The comparison worker could not start: $error',
          ),
        );
      });

  return completer.future.then((result) {
    deadline.cancel();
    return result;
  });
}

void _diffWorkerMain(_DiffRequest request) {
  try {
    request.reply.send(
      _DiffReply(
        unifiedDiff(
          request.oldText,
          request.newText,
          oldLabel: request.oldLabel,
          newLabel: request.newLabel,
          context: request.context,
          outputLimit: request.outputLimit,
        ),
        null,
      ),
    );
  } catch (error) {
    request.reply.send(_DiffReply(null, '$error'));
  }
}
