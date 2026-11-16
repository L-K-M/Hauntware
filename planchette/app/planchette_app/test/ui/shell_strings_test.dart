import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_workspace.dart';

import '../services/document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments;
import '../services/memory_settings.dart' show testSettings;

/// Records the native menu tree without requiring AppKit.
final class _RecordingMenuDelegate extends PlatformMenuDelegate {
  List<PlatformMenuItem> menus = const [];

  @override
  void clearMenus() => menus = const [];

  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) => menus = topLevelMenus;

  @override
  bool debugLockDelegate(BuildContext context) => true;

  @override
  bool debugUnlockDelegate(BuildContext context) => true;
}

/// The menu tree as an indented outline of labels, one per line; groups
/// are separated by `--` and platform-provided items are omitted.
String _outline(List<PlatformMenuItem> items, [String indent = '']) {
  final lines = <String>[];
  for (final item in items) {
    switch (item) {
      case PlatformMenu(:final label, :final menus):
        lines.add('$indent$label');
        final inner = _outline(menus, '$indent  ');
        if (inner.isNotEmpty) lines.add(inner);
      case PlatformMenuItemGroup(:final members):
        final inner = _outline(members, indent);
        if (inner.isEmpty) continue;
        lines.add('$indent--');
        lines.add(inner);
      case PlatformProvidedMenuItem():
        continue;
      default:
        lines.add('$indent${item.label}');
    }
  }
  return lines.join('\n');
}

/// F7: moving the shell's copy into the ARB catalog keeps Planchette's
/// English exactly as it was. The outline below was captured from the
/// shell before the move; the text tools' rows are the editor feed's,
/// whose own parity test lives in editor_strings_test.dart.
void main() {
  testWidgets('the English menus read as before the catalog move', (
    tester,
  ) async {
    final delegate = _RecordingMenuDelegate();
    final original = WidgetsBinding.instance.platformMenuDelegate;
    WidgetsBinding.instance.platformMenuDelegate = delegate;
    final workspace = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
    );
    addTearDown(() {
      WidgetsBinding.instance.platformMenuDelegate = original;
      workspace.dispose();
    });
    final settings = testSettings(
      initial: AppSettings(
        themeMode: ThemeMode.light,
        recentDocuments: [
          '/docs/a/notes.txt',
          '/docs/b/notes.txt',
          '/docs/todo.md',
        ],
      ),
    );
    expect(workspace.newDocument(), isNotNull);
    await tester.pumpWidget(
      PlanchetteApp(
        workspace: workspace,
        settings: settings,
        onQuit: () async {},
        pickFolder: () async => null,
      ),
    );
    await tester.pumpAndSettle();

    final outline = _outline(delegate.menus);
    final dump = Platform.environment['PLANCHETTE_DUMP_MENUS'];
    if (dump != null) File(dump).writeAsStringSync(outline);
    expect(outline, _expectedMacOutline.trimRight());
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}

const _expectedMacOutline = r'''
Planchette
  --
  Settings…
  Quit Planchette
File
  --
  New
  Open…
  Open Recent
    --
    notes.txt (/docs/a)
    notes.txt (/docs/b)
    todo.md
    Clear Menu
  Open Folder…
  Open Containing Folder
  --
  Save
  Save As…
  Save All
  Revert to Saved
  Export as HTML…
  Copy Path
  --
  Close Tab
  Reopen Closed Tab
Edit
  --
  Undo
  Redo
  --
  Cut
  Copy
  Paste
  Select All
  --
  Duplicate Line
  Move Line Up
  Move Line Down
  Delete Line
  Join Lines
  --
  Toggle Comment
  --
  Select Line
  Select Paragraph
  Select Enclosing Brackets
  --
  Insert Line Above
  Insert Line Below
  Copy Line
  Cut Line
  Increment Number
  Decrement Number
  Paste and Match Indentation
Text
  --
  Repeat
  Recent
    --
    No Recent Runs
  --
  Browse Text Tools…
  Lines
    --
    Sort Lines…
    Reverse Lines
    Shuffle Lines
    Remove Duplicate Lines…
    Remove Blank Lines
    Collapse Blank Lines
    Keep Lines Matching…
    Delete Lines Matching…
    Prefix/Suffix Lines…
    Number Lines…
  Case
    --
    UPPERCASE
    lowercase
    Title Case
    Sentence case
    camelCase
    PascalCase
    snake_case
    kebab-case
    CONSTANT_CASE
  Whitespace
    --
    Trim Trailing Whitespace
    Trim Leading Whitespace
    Normalize Spaces
    Convert Indentation to Spaces
    Convert Indentation to Tabs
    Convert Tabs to Spaces…
    Normalize Line Endings
  Clean Up
    --
    Zap Gremlins…
    Straighten Quotes
    Remove ANSI Escapes
    Convert to ASCII
    Strip Diacritics
    Compose Accents
    Decompose Accents
  Wrap
    --
    Hard Wrap…
    Unwrap Paragraphs
    Join Lines With…
  Encode
    --
    URL Encode
    URL Decode
    Base64 Encode
    Base64 Decode
    Encode HTML Entities
    Decode HTML Entities
    Escape as JSON String
    Unescape Backslash Sequences
    Format JSON
    Minify JSON
  Insert
    --
    Date
    Date and Time
    UTC Timestamp
    UUID
Find
  --
  Find…
  Replace…
  Find Next
  Find Previous
  Find in Selection
  Extract Matches…
  --
  Go to Matching Bracket
  Select to Matching Bracket
  --
  Go to Line…
  Next Problem
  Previous Problem
  --
  Compare with Saved
View
  --
  Zoom In
  Zoom Out
  Actual Size
Window
  --
  Command Palette…
  --
  Next Tab
  Previous Tab''';
