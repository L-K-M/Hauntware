import 'package:flutter/foundation.dart';

import 'persisted_setting.dart';

/// A11Y-12's log text sizes, in logical pixels before the system's text
/// scale.
const int kLogTextSizeMin = 10;
const int kLogTextSizeMax = 18;
const int kLogTextSizeDefault = 13;

/// Whether a log view wraps long lines.
enum LogWrap {
  /// One row a line, plus one a field a journal row shows; a long line
  /// is cut at the view's edge with an ellipsis.
  off,

  /// Long lines wrap; a line is measured once per width when a layout
  /// shows it, and keeps an earlier count or an estimate until then.
  on,
}

/// How every log view on this device draws its lines (A11Y-12): the text
/// size and whether long lines wrap.
@immutable
final class LogDisplay {
  /// [textSize] is clamped to [kLogTextSizeMin]..[kLogTextSizeMax].
  LogDisplay({int textSize = kLogTextSizeDefault, this.wrap = LogWrap.off})
    : textSize = textSize.clamp(kLogTextSizeMin, kLogTextSizeMax);

  final int textSize;
  final LogWrap wrap;

  LogDisplay copyWith({int? textSize, LogWrap? wrap}) =>
      LogDisplay(textSize: textSize ?? this.textSize, wrap: wrap ?? this.wrap);

  @override
  bool operator ==(Object other) =>
      other is LogDisplay && other.textSize == textSize && other.wrap == wrap;

  @override
  int get hashCode => Object.hash(textSize, wrap);
}

/// What Settings reads and changes of the log display, apart from where
/// it runs: [LogDisplayController] in the app, and a copy kept over the
/// settings link in the desktop settings window.
abstract interface class LogDisplaySettings
    implements ValueListenable<LogDisplay> {
  /// Picks [display]; a no-op when it is in force and saved. A change
  /// applied but not saved throws [LogDisplayNotSavedException], in the
  /// app and, over the link, in the window; any other throw means it did
  /// not apply.
  Future<void> setLogDisplay(LogDisplay display);
}

/// A log display that applied but was not saved: it lasts until the app
/// restarts unless a later save carries it. [message] is what the failed
/// save printed.
final class LogDisplayNotSavedException implements Exception {
  const LogDisplayNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's log display (A11Y-12): the composition root restores it from
/// `settings.json` and saves every change there; without a save callback,
/// as in most tests, it is held in memory only. A change applies before it
/// is saved, as the appearance does.
final class LogDisplayController extends PersistedSetting<LogDisplay>
    implements LogDisplaySettings {
  LogDisplayController({LogDisplay? display, this._save})
    : super(display ?? LogDisplay());

  final Future<void> Function(int textSize, bool wrap)? _save;

  @override
  Future<void> setLogDisplay(LogDisplay display) => change(display);

  @override
  Future<void>? save(LogDisplay display) =>
      _save?.call(display.textSize, display.wrap == LogWrap.on);

  @override
  Exception notSaved(Object error) =>
      LogDisplayNotSavedException('The log display was not saved: $error');
}
