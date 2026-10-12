import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

/// The edit distance one box of the search may explore before it splits at
/// its furthest point instead (06 §6). It bounds the worst case of two
/// 20 000-line inputs at a fraction of a second; a result that needed the
/// split reports itself as not [LineDiff.minimal].
const int lineDiffCostLimit = 1024;

/// One maximal run of changed lines: [leftCount] lines from [leftStart] on
/// the left stand where [rightCount] lines from [rightStart] stand on the
/// right. Line numbers are 0-based; either count may be 0, never both.
final class LineDiffRegion {
  const LineDiffRegion({
    required this.leftStart,
    required this.leftCount,
    required this.rightStart,
    required this.rightCount,
  });

  final int leftStart;
  final int leftCount;
  final int rightStart;
  final int rightCount;

  @override
  bool operator ==(Object other) =>
      other is LineDiffRegion &&
      other.leftStart == leftStart &&
      other.leftCount == leftCount &&
      other.rightStart == rightStart &&
      other.rightCount == rightCount;

  @override
  int get hashCode => Object.hash(leftStart, leftCount, rightStart, rightCount);

  @override
  String toString() =>
      'LineDiffRegion($leftStart+$leftCount, $rightStart+$rightCount)';
}

/// The changed regions between two line lists, in order. Neighbouring
/// regions are separated by at least one equal line, so `regions.length` is
/// the number of changed regions a reader steps through.
final class LineDiff {
  LineDiff._(
    List<LineDiffRegion> regions, {
    required this.leftLineCount,
    required this.rightLineCount,
    required this.minimal,
  }) : regions = List.unmodifiable(regions);

  final List<LineDiffRegion> regions;
  final int leftLineCount;
  final int rightLineCount;

  /// False when a box hit the cost limit and split at its furthest point:
  /// every region is still a real difference, but some may be larger than
  /// the smallest possible edit.
  final bool minimal;
}

/// Myers' O(ND) difference algorithm (Myers 1986, with the linear-space
/// refinement of §4b) over whole lines.
///
/// Lines are interned to integers, the common prefix and suffix are
/// skipped, and lines that occur on only one side are marked changed before
/// the search: no common subsequence can use them, so dropping them keeps
/// the result minimal while shrinking the boxes the search explores.
LineDiff diffLines(
  List<String> left,
  List<String> right, {
  int costLimit = lineDiffCostLimit,
}) {
  if (costLimit < 1) throw ArgumentError.value(costLimit, 'costLimit');

  final ids = HashMap<String, int>();
  int intern(String line) => ids.putIfAbsent(line, () => ids.length);
  final a = Int32List(left.length);
  for (var i = 0; i < left.length; i++) {
    a[i] = intern(left[i]);
  }
  final b = Int32List(right.length);
  for (var j = 0; j < right.length; j++) {
    b[j] = intern(right[j]);
  }

  final leftChanged = Uint8List(a.length);
  final rightChanged = Uint8List(b.length);
  final minimal = _markChanges(
    a,
    b,
    leftChanged,
    rightChanged,
    idCount: ids.length,
    costLimit: costLimit,
  );
  return LineDiff._(
    _regions(leftChanged, rightChanged),
    leftLineCount: a.length,
    rightLineCount: b.length,
    minimal: minimal,
  );
}

/// Marks every line outside one common subsequence; returns whether that
/// subsequence is a longest one.
bool _markChanges(
  Int32List a,
  Int32List b,
  Uint8List leftChanged,
  Uint8List rightChanged, {
  required int idCount,
  required int costLimit,
}) {
  var aLo = 0;
  var bLo = 0;
  var aHi = a.length;
  var bHi = b.length;
  while (aLo < aHi && bLo < bHi && a[aLo] == b[bLo]) {
    aLo++;
    bLo++;
  }
  while (aLo < aHi && bLo < bHi && a[aHi - 1] == b[bHi - 1]) {
    aHi--;
    bHi--;
  }

  final onLeft = Uint8List(idCount);
  final onRight = Uint8List(idCount);
  for (var i = aLo; i < aHi; i++) {
    onLeft[a[i]] = 1;
  }
  for (var j = bLo; j < bHi; j++) {
    onRight[b[j]] = 1;
  }

  final keptLeft = <int>[];
  for (var i = aLo; i < aHi; i++) {
    if (onRight[a[i]] == 1) {
      keptLeft.add(i);
    } else {
      leftChanged[i] = 1;
    }
  }
  final keptRight = <int>[];
  for (var j = bLo; j < bHi; j++) {
    if (onLeft[b[j]] == 1) {
      keptRight.add(j);
    } else {
      rightChanged[j] = 1;
    }
  }

  final search = _MyersSearch(
    Int32List.fromList([for (final i in keptLeft) a[i]]),
    Int32List.fromList([for (final j in keptRight) b[j]]),
    costLimit: costLimit,
  )..run();
  for (var i = 0; i < keptLeft.length; i++) {
    leftChanged[keptLeft[i]] = search.leftChanged[i];
  }
  for (var j = 0; j < keptRight.length; j++) {
    rightChanged[keptRight[j]] = search.rightChanged[j];
  }
  return search.minimal;
}

/// The bidirectional middle-snake search. Boxes wait on an explicit stack,
/// so a long chain of splits never deepens the call stack.
///
/// Inside a box of n left and m right lines, diagonal k holds the points
/// with x - y == k. The forward arrays store, per diagonal, the furthest x a
/// path of d edits from the box's start reaches; the backward arrays do the
/// same from the box's end over the reversed lines, where reversed diagonal
/// r meets forward diagonal `n - m - r`. A box splits where the two
/// frontiers first overlap; that point lies on a shortest edit path.
final class _MyersSearch {
  _MyersSearch(this._a, this._b, {required this._costLimit})
    : leftChanged = Uint8List(_a.length),
      rightChanged = Uint8List(_b.length),
      _offset = ((_a.length + _b.length + 1) >> 1) + 1 {
    _forward = Int32List(2 * _offset + 1);
    _backward = Int32List(2 * _offset + 1);
  }

  final Int32List _a;
  final Int32List _b;
  final int _costLimit;
  final Uint8List leftChanged;
  final Uint8List rightChanged;
  final int _offset;
  late final Int32List _forward;
  late final Int32List _backward;

  bool minimal = true;
  int _splitX = 0;
  int _splitY = 0;

  void run() {
    final boxes = <int>[0, _a.length, 0, _b.length];
    while (boxes.isNotEmpty) {
      var bHi = boxes.removeLast();
      var bLo = boxes.removeLast();
      var aHi = boxes.removeLast();
      var aLo = boxes.removeLast();
      while (aLo < aHi && bLo < bHi && _a[aLo] == _b[bLo]) {
        aLo++;
        bLo++;
      }
      while (aLo < aHi && bLo < bHi && _a[aHi - 1] == _b[bHi - 1]) {
        aHi--;
        bHi--;
      }
      if (aLo == aHi || bLo == bHi) {
        _markBox(aLo, aHi, bLo, bHi);
        continue;
      }
      if (!_split(aLo, aHi, bLo, bHi)) {
        minimal = false;
        _markBox(aLo, aHi, bLo, bHi);
        continue;
      }
      boxes.addAll([_splitX, aHi, _splitY, bHi, aLo, _splitX, bLo, _splitY]);
    }
  }

  void _markBox(int aLo, int aHi, int bLo, int bHi) {
    leftChanged.fillRange(aLo, aHi, 1);
    rightChanged.fillRange(bLo, bHi, 1);
  }

  /// Finds a split strictly inside the box (which starts and ends on
  /// different lines on each side), leaving it in [_splitX] and [_splitY].
  /// Past the cost limit the split is the frontier point that got furthest
  /// from either end, and the result stops being minimal.
  bool _split(int aLo, int aHi, int bLo, int bHi) {
    final n = aHi - aLo;
    final m = bHi - bLo;
    final delta = n - m;
    final overlapOnForward = delta.isOdd;
    final maxD = (n + m + 1) >> 1;
    final limit = math.min(maxD, _costLimit);
    final o = _offset;
    _forward.fillRange(o - maxD - 1, o + maxD + 2, -1);
    _backward.fillRange(o - maxD - 1, o + maxD + 2, -1);

    for (var d = 0; d <= limit; d++) {
      // Diagonals a d-edit path can reach without leaving the box.
      final kLo = d <= m ? -d : -m + ((d - m) & 1);
      final kHi = d <= n ? d : n - ((d - n) & 1);

      for (var k = kLo; k <= kHi; k += 2) {
        var x = _reach(_forward, d, k, n, m);
        if (x < 0) {
          _forward[o + k] = -1;
          continue;
        }
        var y = x - k;
        while (x < n && y < m && _a[aLo + x] == _b[bLo + y]) {
          x++;
          y++;
        }
        _forward[o + k] = x;
        if (!overlapOnForward) continue;

        final r = delta - k;
        if (r < 1 - d || r > d - 1) continue;
        final back = _backward[o + r];
        if (back >= 0 && x + back >= n) {
          _splitX = aLo + x;
          _splitY = bLo + y;
          return true;
        }
      }

      for (var k = kLo; k <= kHi; k += 2) {
        var x = _reach(_backward, d, k, n, m);
        if (x < 0) {
          _backward[o + k] = -1;
          continue;
        }
        var y = x - k;
        while (x < n && y < m && _a[aHi - 1 - x] == _b[bHi - 1 - y]) {
          x++;
          y++;
        }
        _backward[o + k] = x;
        if (overlapOnForward) continue;

        final f = delta - k;
        if (f < -d || f > d) continue;
        final front = _forward[o + f];
        if (front >= 0 && front + x >= n) {
          _splitX = aHi - x;
          _splitY = bHi - y;
          return true;
        }
      }
    }

    // A shortest path always overlaps by maxD, so only the cost limit gets
    // here.
    assert(limit < maxD, 'the middle-snake search missed an overlap');
    return _splitAtFrontier(aLo, aHi, bLo, bHi, limit);
  }

  /// The furthest x a d-edit path reaches on diagonal [k] before its final
  /// snake: one step down from k + 1 or right from k - 1, whichever lands
  /// further, or -1 when neither neighbour reached a point inside the box.
  int _reach(Int32List v, int d, int k, int n, int m) {
    if (d == 0) return 0;
    final o = _offset;
    var x = -1;
    if (k + 1 <= d - 1) {
      final down = v[o + k + 1];
      if (down >= 0 && down - k <= m) x = down;
    }
    if (k - 1 >= 1 - d) {
      final right = v[o + k - 1];
      if (right >= 0 && right < n && right + 1 > x) x = right + 1;
    }
    return x;
  }

  bool _splitAtFrontier(int aLo, int aHi, int bLo, int bHi, int d) {
    final n = aHi - aLo;
    final m = bHi - bLo;
    final o = _offset;
    final kLo = d <= m ? -d : -m + ((d - m) & 1);
    final kHi = d <= n ? d : n - ((d - n) & 1);

    var forwardProgress = -1;
    var forwardX = 0;
    var backwardProgress = -1;
    var backwardX = 0;
    var forwardK = 0;
    var backwardK = 0;
    for (var k = kLo; k <= kHi; k += 2) {
      final fx = _forward[o + k];
      if (fx >= 0 && 2 * fx - k > forwardProgress) {
        forwardProgress = 2 * fx - k;
        forwardX = fx;
        forwardK = k;
      }
      final bx = _backward[o + k];
      if (bx >= 0 && 2 * bx - k > backwardProgress) {
        backwardProgress = 2 * bx - k;
        backwardX = bx;
        backwardK = k;
      }
    }

    if (forwardProgress >= backwardProgress) {
      _splitX = aLo + forwardX;
      _splitY = bLo + forwardX - forwardK;
    } else {
      _splitX = aHi - backwardX;
      _splitY = bHi - (backwardX - backwardK);
    }
    minimal = false;
    final inside =
        _splitX + _splitY > aLo + bLo && _splitX + _splitY < aHi + bHi;
    return inside;
  }
}

/// Pairs the unchanged lines in order and gathers the rest into maximal
/// regions. Both sides keep the same number of unchanged lines, so the walk
/// never strands one.
List<LineDiffRegion> _regions(Uint8List leftChanged, Uint8List rightChanged) {
  final regions = <LineDiffRegion>[];
  var i = 0;
  var j = 0;
  while (i < leftChanged.length || j < rightChanged.length) {
    final leftEqual = i < leftChanged.length && leftChanged[i] == 0;
    final rightEqual = j < rightChanged.length && rightChanged[j] == 0;
    if (leftEqual && rightEqual) {
      i++;
      j++;
      continue;
    }

    final leftStart = i;
    final rightStart = j;
    while (i < leftChanged.length && leftChanged[i] == 1) {
      i++;
    }
    while (j < rightChanged.length && rightChanged[j] == 1) {
      j++;
    }
    if (i == leftStart && j == rightStart) {
      throw StateError('unchanged lines no longer pair up');
    }
    regions.add(
      LineDiffRegion(
        leftStart: leftStart,
        leftCount: i - leftStart,
        rightStart: rightStart,
        rightCount: j - rightStart,
      ),
    );
  }
  return regions;
}

/// How a diff's regions become display rows.
enum LineDiffLayout {
  /// Removed and added lines share rows, the shorter side padded with gaps.
  sideBySide,

  /// One column: each region's removed lines, then its added lines.
  unified,
}

/// What one display row shows.
enum LineDiffRowKind {
  /// The same line on both sides.
  unchanged,

  /// A removed line beside an added one (side by side only).
  changed,

  /// A line only the left side has; side by side, a gap faces it.
  leftOnly,

  /// A line only the right side has; side by side, a gap faces it.
  rightOnly,
}

/// A diff laid out as rows, with each row's lines and region and the way
/// back from a line or a region to its row.
final class LineDiffRows {
  LineDiffRows._(
    this._left,
    this._right,
    this._kinds,
    this._regions,
    this._regionFirstRows,
    this._leftRows,
    this._rightRows,
  );

  final Int32List _left;
  final Int32List _right;
  final Uint8List _kinds;
  final Int32List _regions;
  final Int32List _regionFirstRows;
  final Int32List _leftRows;
  final Int32List _rightRows;

  int get length => _kinds.length;

  int get regionCount => _regionFirstRows.length;

  /// The 0-based left line [row] shows, or -1 for a gap or a right-only row.
  int leftLineAt(int row) => _left[row];

  /// The 0-based right line [row] shows, or -1 for a gap or a left-only row.
  int rightLineAt(int row) => _right[row];

  LineDiffRowKind kindAt(int row) => LineDiffRowKind.values[_kinds[row]];

  /// The region [row] belongs to, or -1 for an unchanged row.
  int regionAt(int row) => _regions[row];

  int regionFirstRow(int region) => _regionFirstRows[region];

  int rowOfLeftLine(int line) => _leftRows[line];

  int rowOfRightLine(int line) => _rightRows[line];
}

LineDiffRows alignLineDiff(LineDiff diff, LineDiffLayout layout) {
  var changedLeft = 0;
  var changedRows = 0;
  for (final region in diff.regions) {
    changedLeft += region.leftCount;
    changedRows += switch (layout) {
      LineDiffLayout.sideBySide => math.max(
        region.leftCount,
        region.rightCount,
      ),
      LineDiffLayout.unified => region.leftCount + region.rightCount,
    };
  }
  final length = diff.leftLineCount - changedLeft + changedRows;

  final left = Int32List(length);
  final right = Int32List(length);
  final kinds = Uint8List(length);
  final regions = Int32List(length);
  final regionFirstRows = Int32List(diff.regions.length);
  final leftRows = Int32List(diff.leftLineCount);
  final rightRows = Int32List(diff.rightLineCount);

  var row = 0;
  void put(int l, int r, LineDiffRowKind kind, int region) {
    left[row] = l;
    right[row] = r;
    kinds[row] = kind.index;
    regions[row] = region;
    if (l >= 0) leftRows[l] = row;
    if (r >= 0) rightRows[r] = row;
    row++;
  }

  var l = 0;
  var r = 0;
  void equalUntil(int leftEnd) {
    while (l < leftEnd) {
      put(l++, r++, LineDiffRowKind.unchanged, -1);
    }
  }

  for (var index = 0; index < diff.regions.length; index++) {
    final region = diff.regions[index];
    equalUntil(region.leftStart);
    regionFirstRows[index] = row;
    switch (layout) {
      case LineDiffLayout.sideBySide:
        final rows = math.max(region.leftCount, region.rightCount);
        for (var k = 0; k < rows; k++) {
          final hasLeft = k < region.leftCount;
          final hasRight = k < region.rightCount;
          put(
            hasLeft ? region.leftStart + k : -1,
            hasRight ? region.rightStart + k : -1,
            hasLeft && hasRight
                ? LineDiffRowKind.changed
                : (hasLeft
                      ? LineDiffRowKind.leftOnly
                      : LineDiffRowKind.rightOnly),
            index,
          );
        }
      case LineDiffLayout.unified:
        for (var k = 0; k < region.leftCount; k++) {
          put(region.leftStart + k, -1, LineDiffRowKind.leftOnly, index);
        }
        for (var k = 0; k < region.rightCount; k++) {
          put(-1, region.rightStart + k, LineDiffRowKind.rightOnly, index);
        }
    }
    l = region.leftStart + region.leftCount;
    r = region.rightStart + region.rightCount;
  }
  equalUntil(diff.leftLineCount);

  return LineDiffRows._(
    left,
    right,
    kinds,
    regions,
    regionFirstRows,
    leftRows,
    rightRows,
  );
}
