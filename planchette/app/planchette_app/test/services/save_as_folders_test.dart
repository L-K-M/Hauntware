import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_editor/planchette_editor.dart' show HtmlPalette;
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments, document, testPath;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final docs = testPath('docs');
  final notes = testPath('notes');

  group('SaveAsFolders', () {
    test('prefers the extension, then the last folder, then none', () {
      const empty = SaveAsFolders();
      expect(empty.initialFolderFor('Untitled'), isNull);

      final folders = empty
          .recorded(paths.join(docs, 'a.md'))
          .recorded(paths.join(notes, 'b.txt'));
      expect(folders.initialFolderFor('c.MD'), docs);
      expect(folders.initialFolderFor('d.txt'), notes);
      // An unseen extension, or none at all, takes the last folder used.
      expect(folders.initialFolderFor('e.json'), notes);
      expect(folders.initialFolderFor('Untitled'), notes);
      expect(
        folders.recorded(paths.join(docs, 'Untitled')).initialFolderFor('x'),
        docs,
      );
    });

    test('forgets the least recently used extension past the limit', () {
      var folders = const SaveAsFolders();
      for (var i = 0; i <= SaveAsFolders.maximumExtensions; i++) {
        folders = folders.recorded(paths.join(docs, 'f.e$i'));
      }
      expect(folders.byExtension, hasLength(SaveAsFolders.maximumExtensions));
      expect(folders.byExtension.containsKey('.e0'), isFalse);
    });

    test('round-trips through settings and drops relative folders', () {
      final folders = const SaveAsFolders().recorded(paths.join(docs, 'a.md'));
      final settings = const AppSettings().copyWith(saveAsFolders: folders);
      expect(AppSettings.fromJson(settings.toJson()), settings);
      expect(
        SaveAsFolders.fromJson({
          'byExtension': {'.md': 'relative/folder', '.txt': docs},
          'last': 'relative',
        }),
        SaveAsFolders(byExtension: {'.txt': docs}),
      );
      expect(const AppSettings().toJson(), isNot(contains('saveAsFolders')));
    });
  });

  group('where Save As opens', () {
    late MemoryDocuments store;
    late FakeDialogs dialogs;
    late DocumentWorkspace workspace;
    final saved = <String>[];
    setUp(() {
      store = MemoryDocuments();
      dialogs = FakeDialogs();
      saved.clear();
      workspace = DocumentWorkspace(store: store, dialogs: dialogs)
        ..onSavedToChosenPath = saved.add;
    });
    tearDown(() => workspace.dispose());

    test('a saved file opens in its own folder', () async {
      store.files[testPath('one.txt')] = document('one.txt', 'disk');
      await workspace.open(testPath('one.txt'));
      workspace.saveAsFolders = const SaveAsFolders().recorded(
        paths.join(docs, 'x.txt'),
      );
      dialogs.savePath = null;
      await workspace.save(workspace.active!, saveAs: true);
      expect(dialogs.savePrompts.single, testPath('one.txt'));
    });

    test('an untitled document opens in the folder for its extension, '
        'then the last one', () async {
      workspace.saveAsFolders = const SaveAsFolders()
          .recorded(paths.join(docs, 'a.md'))
          .recorded(paths.join(notes, 'b.txt'));
      final tab = workspace.newDocument()!;
      tab.editor.text.text = 'text';
      dialogs.savePath = null;
      await workspace.save(tab);
      // "Untitled" has no extension: the last folder used.
      expect(dialogs.savePrompts.single, paths.join(notes, 'Untitled'));

      workspace.saveAsFolders = const SaveAsFolders()
          .recorded(paths.join(docs, 'Untitled'))
          .recorded(paths.join(notes, 'b.txt'));
      await workspace.save(tab);
      expect(dialogs.savePrompts.last, paths.join(docs, 'Untitled'));
    });

    test('with nothing remembered the system default is used', () async {
      final tab = workspace.newDocument()!;
      tab.editor.text.text = 'text';
      dialogs.savePath = null;
      await workspace.save(tab);
      expect(dialogs.savePrompts.single, 'Untitled');
    });

    test('a chosen destination is reported once it is saved', () async {
      final tab = workspace.newDocument()!;
      tab.editor.text.text = 'text';
      dialogs.savePath = paths.join(docs, 'new.md');
      expect(await workspace.save(tab), isTrue);
      expect(saved, [paths.join(docs, 'new.md')]);

      // A plain save to the same file chose nothing.
      tab.editor.text.text = 'more';
      expect(await workspace.save(tab), isTrue);
      expect(saved, hasLength(1));

      // A cancelled Save As reports nothing either.
      dialogs.savePath = null;
      expect(await workspace.save(tab, saveAs: true), isFalse);
      expect(saved, hasLength(1));
    });

    test('an HTML export suggests and records like a save', () async {
      workspace.saveAsFolders = const SaveAsFolders().recorded(
        paths.join(docs, 'page.html'),
      );
      final tab = workspace.newDocument()!;
      tab.editor.text.text = 'text';
      dialogs.savePath = paths.join(notes, 'Untitled.html');
      const palette = HtmlPalette(
        background: '#ffffff',
        foreground: '#000000',
        tokens: {},
      );
      expect(await workspace.exportHtml(tab, palette), isTrue);
      expect(dialogs.savePrompts.single, paths.join(docs, 'Untitled.html'));
      expect(saved, [paths.join(notes, 'Untitled.html')]);
    });
  });
}
