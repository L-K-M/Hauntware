import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Formats a [ShortcutActivator] for display (Poltergeist 02 §8.4's palette
/// rows show the chord they accept; the menus render their own). Modifier
/// order and glyphs follow the platform convention: ⌃⌥⇧⌘ on macOS,
/// `Ctrl+Alt+Shift+Meta+` elsewhere. Only [SingleActivator] has a
/// spelling — anything else yields null and the row shows no hint.
String? formatShortcutActivator(
  ShortcutActivator activator,
  TargetPlatform platform,
) {
  if (activator is! SingleActivator) return null;
  // iPadOS hardware keyboards use ⌘ too — glyph platforms, like the
  // hosts' old formatters.
  final mac =
      platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  final buffer = StringBuffer();
  void mod(bool flag, String macGlyph, String name) {
    if (!flag) return;
    buffer.write(mac ? macGlyph : '$name+');
  }

  // macOS prints modifiers in ⌃⌥⇧⌘ order; other platforms spell them.
  mod(activator.control, '⌃', 'Ctrl');
  mod(activator.alt, '⌥', 'Alt');
  mod(activator.shift, '⇧', 'Shift');
  mod(activator.meta, '⌘', 'Meta');
  buffer.write(_keyGlyph(activator.trigger, mac));
  return buffer.toString();
}

/// The trigger key's display glyph: arrows and editing keys get symbols
/// on macOS and names elsewhere; letter/digit keys come from
/// [LogicalKeyboardKey.keyLabel] (already uppercase for letters).
String _keyGlyph(LogicalKeyboardKey key, bool mac) {
  final named = switch (key) {
    LogicalKeyboardKey.arrowUp => mac ? '↑' : 'Up',
    LogicalKeyboardKey.arrowDown => mac ? '↓' : 'Down',
    LogicalKeyboardKey.arrowLeft => mac ? '←' : 'Left',
    LogicalKeyboardKey.arrowRight => mac ? '→' : 'Right',
    LogicalKeyboardKey.enter => mac ? '↩' : 'Enter',
    LogicalKeyboardKey.tab => mac ? '⇥' : 'Tab',
    LogicalKeyboardKey.escape => 'Esc',
    LogicalKeyboardKey.backspace => mac ? '⌫' : 'Backspace',
    LogicalKeyboardKey.delete => mac ? '⌦' : 'Del',
    LogicalKeyboardKey.space => 'Space',
    LogicalKeyboardKey.comma => ',',
    LogicalKeyboardKey.period => '.',
    LogicalKeyboardKey.slash => '/',
    LogicalKeyboardKey.backslash => '\\',
    LogicalKeyboardKey.bracketLeft => '[',
    LogicalKeyboardKey.bracketRight => ']',
    LogicalKeyboardKey.minus => '-',
    LogicalKeyboardKey.equal => '=',
    LogicalKeyboardKey.semicolon => ';',
    LogicalKeyboardKey.quote => "'",
    LogicalKeyboardKey.backquote => '`',
    _ => null,
  };
  return named ?? key.keyLabel;
}

/// One key binding a [GhostChordScope] or [dispatchGhostChord] honours:
/// [activator] runs [onInvoke]. The fields mirror the policies the Ghost
/// hosts' chord layers share.
final class GhostChordBinding {
  const GhostChordBinding({
    required this.activator,
    required this.onInvoke,
    this.repeats = true,
    this.leftAltOnly = false,
    this.mayRunFrom,
  });

  final ShortcutActivator activator;

  /// Called when the chord fires. Hosts put their enablement checks and
  /// error boundaries inside.
  final VoidCallback onInvoke;

  /// Whether a held chord invokes on key repeats, or swallows them.
  /// Set false for one-shot commands (a held close would take out a row
  /// of tabs before the key came back up); a repeat still counts as
  /// handled, so nothing under the layer sees the keys underneath.
  final bool repeats;

  /// The chord stands down while the right Alt is held: Windows reports
  /// AltGr as Ctrl + right Alt (and some Linux setups as right Alt), so
  /// e.g. AltGr+digit would otherwise swallow a typed character.
  final bool leftAltOnly;

  /// Whether the chord may run while [focus] holds primary focus; a null
  /// or returning-true guard runs it. A refused chord is still handled —
  /// the keystroke is consumed rather than running behind the user's
  /// back (Poltergeist's delete-family rule).
  final bool Function(FocusNode? focus)? mayRunFrom;
}

/// Dispatches [event] against [bindings]: the one decision behind both a
/// [GhostChordScope] and direct key handlers (Séance's terminal, which has
/// to see the chords before xterm turns them into bytes for the shell).
///
/// A match is always [KeyEventResult.handled], even a held repeat its
/// binding does not act on or a binding whose [GhostChordBinding.mayRunFrom]
/// refuses — ignored, the keys underneath would leak to the surface below.
/// Non-down/repeat events and unmatched keys return ignored.
KeyEventResult dispatchGhostChord(
  List<GhostChordBinding> bindings,
  KeyEvent event,
) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  final keys = HardwareKeyboard.instance;
  final focus = FocusManager.instance.primaryFocus;
  var result = KeyEventResult.ignored;
  for (final binding in bindings) {
    if (!binding.activator.accepts(event, keys)) continue;
    if (binding.leftAltOnly &&
        keys.logicalKeysPressed.contains(LogicalKeyboardKey.altRight)) {
      continue;
    }
    if ((event is KeyDownEvent || binding.repeats) &&
        (binding.mayRunFrom?.call(focus) ?? true)) {
      binding.onInvoke();
    }
    result = KeyEventResult.handled;
  }
  return result;
}

/// What [GhostChordScope] does with a chord that carries no Ctrl/Alt/Meta
/// modifier. [GhostUnmodifiedChordPolicy.ignore] keeps unmodified keys
/// with the focused surface (they type text or navigate); [allowlisted]
/// additionally binds the listed trigger keys (the Commander-style
/// F5/F6/F7 file verbs); [allow] binds every chord, for hosts whose
/// fields leave those keys to the layer above.
enum GhostUnmodifiedChordPolicy { ignore, allow, allowlisted }

bool _isUnmodified(ShortcutActivator activator) => switch (activator) {
  SingleActivator a => !a.control && !a.meta && !a.alt,
  CharacterActivator a => !a.control && !a.meta && !a.alt,
  _ => false,
};

/// Dispatches [GhostChordBinding]s from a focus node that never takes
/// focus itself — the shared spine of the hosts' app-level chord layers.
///
/// While [suspendWhileEditing] holds, a primary focus inside
/// [EditableText] ignores every chord so the event keeps propagating to
/// the field's own editing shortcuts; a consumed command chord would
/// otherwise swallow ⌘A mid-typing. Hosts whose fields leave those keys
/// unhandled (a document editor's shell chords) pass false.
class GhostChordScope extends StatelessWidget {
  const GhostChordScope({
    super.key,
    required this.bindings,
    this.suspendWhileEditing = true,
    this.unmodifiedPolicy = GhostUnmodifiedChordPolicy.ignore,
    this.unmodifiedTriggers = const <LogicalKeyboardKey>{},
    required this.child,
  });

  final List<GhostChordBinding> bindings;

  /// See the class doc: true ignores all chords while an [EditableText]
  /// descendant holds primary focus.
  final bool suspendWhileEditing;

  /// How activators without Ctrl/Alt/Meta are treated; see
  /// [GhostUnmodifiedChordPolicy].
  final GhostUnmodifiedChordPolicy unmodifiedPolicy;

  /// Trigger keys bound even unmodified under
  /// [GhostUnmodifiedChordPolicy.allowlisted].
  final Set<LogicalKeyboardKey> unmodifiedTriggers;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // A map keyed on the activator: a later binding for the same chord
    // replaces the earlier one — later-binding-wins, the release-mode
    // fallback the duplicate diagnostics below report.
    final bound = <ShortcutActivator, GhostChordBinding>{};
    for (final binding in bindings) {
      final activator = binding.activator;
      // Unmodified keys — any activator type — stay with the focused
      // surface unless the policy admits them; skip them BEFORE the
      // duplicate diagnostics so an unmodified overlap is not misreported
      // as a chord collision.
      if (_isUnmodified(activator)) {
        final admitted = switch (unmodifiedPolicy) {
          GhostUnmodifiedChordPolicy.allow => true,
          GhostUnmodifiedChordPolicy.ignore => false,
          GhostUnmodifiedChordPolicy.allowlisted =>
            activator is SingleActivator &&
                unmodifiedTriggers.contains(activator.trigger),
        };
        if (!admitted) continue;
      }
      // Two bindings claiming one chord is a registration bug; debug
      // builds fail it immediately (release keeps later-binding-wins,
      // the documented fallback).
      final fresh = !bound.containsKey(activator);
      assert(
        fresh,
        'Duplicate shortcut activator $activator: later binding wins',
      );
      // Release builds keep later-binding-wins silently by design; the
      // print keeps user-reported "shortcut does nothing" diagnosable.
      if (!fresh) {
        debugPrint(
          'Duplicate shortcut activator $activator: later binding wins',
        );
      }
      bound[activator] = binding;
    }

    return Focus(
      // Same posture CallbackShortcuts takes: this node only dispatches,
      // it never takes focus or traversal itself.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        // Field-first precedence: with a text surface focused, chords
        // belong to its editing shortcuts — returning ignored keeps the
        // event propagating upward to them.
        if (suspendWhileEditing) {
          final primary = FocusManager.instance.primaryFocus;
          if (primary?.context?.findAncestorWidgetOfExactType<EditableText>() !=
              null) {
            return KeyEventResult.ignored;
          }
        }
        return dispatchGhostChord(bound.values.toList(), event);
      },
      child: child,
    );
  }
}
