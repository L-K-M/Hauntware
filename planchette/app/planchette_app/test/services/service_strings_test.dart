import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/l10n/app_localizations_en.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'document_workspace_test.dart' show FakeDialogs, MemoryDocuments;
import 'memory_settings.dart';

/// Marks the strings the services read, so a test sees whether a message
/// came from the injected catalog rather than English written in code.
class _Marked extends AppLocalizationsEn {
  @override
  String get untitledName => '[untitled]';
  @override
  String untitledNameNumbered(int number) => '[untitled $number]';
  @override
  String windowTitleDocument(String name) => '[title $name]';
  @override
  String windowTitleUnsaved(String title) => '[unsaved $title]';
  @override
  String settingsSaveFailed(String detail) => '[not saved: $detail]';
}

/// F7: the workspace and the settings controller word their messages
/// through the strings their host injects; without one they read the
/// catalog's English.
void main() {
  test('the workspace names and titles through its strings', () {
    final workspace = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
      strings: _Marked.new,
    );
    addTearDown(workspace.dispose);

    final first = workspace.newDocument()!;
    final second = workspace.newDocument()!;

    expect(first.name, '[untitled]');
    expect(second.name, '[untitled 2]');
    expect(workspace.windowTitle, '[title [untitled 2]]');
    second.editor.text.text = 'edit';
    expect(workspace.windowTitle, '[unsaved [title [untitled 2]]]');
  });

  test('without strings the workspace reads the English catalog', () {
    final workspace = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
    );
    addTearDown(workspace.dispose);

    expect(workspace.windowTitle, 'Planchette');
    workspace.newDocument();
    workspace.newDocument();
    expect(workspace.active!.name, 'Untitled 2');
    expect(workspace.windowTitle, 'Untitled 2 — Planchette');
  });

  test('a failed settings save is worded by the injected strings', () async {
    final store = MemorySettings()..failSaves = true;
    final settings = SettingsController(store: store, strings: _Marked.new);
    addTearDown(settings.dispose);

    await settings.update(const AppSettings(themeMode: ThemeMode.dark));
    await settings.flush();

    expect(settings.error, '[not saved: disk full]');
  });
}
