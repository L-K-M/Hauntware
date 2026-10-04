import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show GhostFileKind, GhostFileNodeType, ghostFileKind;
import 'package:seance_app/family_hues.dart';
import 'package:seance_app/ui/file_kinds.dart';
import 'package:seance_core/seance_core.dart';

/// The Files tab's kind table, ported from Poltergeist so a folder, a
/// photo or a script reads the same in both apps (its D34).
void main() {
  RemoteFileEntry entry(
    String name, [
    RemoteFileType type = RemoteFileType.file,
  ]) => RemoteFileEntry(path: '/x/$name', name: name, type: type);

  group('ghostFileItemOf', () {
    test('keeps each file type under the same name', () {
      for (final type in RemoteFileType.values) {
        expect(
          ghostFileItemOf(entry('a', type)).type.name,
          type.name,
          reason: '$type',
        );
      }
      expect(
        ghostFileItemOf(entry('a', RemoteFileType.file)).type,
        GhostFileNodeType.file,
      );
      expect(
        ghostFileItemOf(entry('a', RemoteFileType.directory)).type,
        GhostFileNodeType.directory,
      );
      expect(
        ghostFileItemOf(entry('a', RemoteFileType.symbolicLink)).type,
        GhostFileNodeType.symbolicLink,
      );
      expect(
        ghostFileItemOf(entry('a', RemoteFileType.other)).type,
        GhostFileNodeType.other,
      );
    });

    test('passes the name through verbatim', () {
      for (final name in ['notes.md', '.bashrc', 'Grüße – 日本.txt']) {
        expect(ghostFileItemOf(entry(name)).name, name);
      }
    });

    test('passes size and modification time through', () {
      final modifiedAt = DateTime.utc(2026, 1, 2, 3, 4);
      final item = ghostFileItemOf(
        RemoteFileEntry(
          path: '/x/a.bin',
          name: 'a.bin',
          type: RemoteFileType.file,
          size: 2048,
          modifiedAt: modifiedAt,
        ),
      );
      expect(item.size, 2048);
      expect(item.modifiedAt, modifiedAt);

      final bare = ghostFileItemOf(entry('a.bin'));
      expect(bare.size, isNull);
      expect(bare.modifiedAt, isNull);
    });

    test('feeds the shared classifier, file type first', () {
      expect(
        ghostFileKind(
          ghostFileItemOf(entry('photos.png', RemoteFileType.directory)),
        ),
        GhostFileKind.folder,
      );
      expect(
        ghostFileKind(
          ghostFileItemOf(entry('latest.zip', RemoteFileType.symbolicLink)),
        ),
        GhostFileKind.link,
      );
    });
  });

  test('the file type wins over any extension', () {
    expect(fileKind(entry('photos.png', RemoteFileType.directory)),
        FileKind.folder);
    expect(fileKind(entry('latest.zip', RemoteFileType.symbolicLink)),
        FileKind.link);
  });

  test('extensions map to their family, case-insensitively', () {
    expect(fileKind(entry('IMG_0001.JPG')), FileKind.image);
    expect(fileKind(entry('main.dart')), FileKind.code);
    expect(fileKind(entry('deploy.sh')), FileKind.code);
    expect(fileKind(entry('notes.md')), FileKind.document);
    expect(fileKind(entry('Report.DOCX')), FileKind.document);
    expect(fileKind(entry('site.tar.gz')), FileKind.archive);
    expect(fileKind(entry('manual.pdf')), FileKind.pdf);
    expect(fileKind(entry('talk.mp4')), FileKind.video);
    expect(fileKind(entry('song.flac')), FileKind.audio);
    expect(fileKind(entry('data.bin')), FileKind.other);
  });

  test('dotfiles and bare names have no extension', () {
    expect(fileKind(entry('.bashrc')), FileKind.other);
    expect(fileKind(entry('Makefile')), FileKind.other);
    expect(fileKind(entry('trailing.')), FileKind.other);
    expect(fileKind(entry('.config.json')), FileKind.code);
  });

  test('each kind wears its family hue, and no two share a glyph', () {
    expect({for (final kind in FileKind.values) kind: fileKindGlyph(kind).$2}, {
      FileKind.folder: FamilyHue.blue,
      FileKind.link: FamilyHue.cyan,
      FileKind.image: FamilyHue.pink,
      FileKind.document: FamilyHue.graphite,
      FileKind.code: FamilyHue.orange,
      FileKind.archive: FamilyHue.brown,
      FileKind.pdf: FamilyHue.red,
      FileKind.audio: FamilyHue.purple,
      FileKind.video: FamilyHue.purple,
      FileKind.other: FamilyHue.graphite,
    });
    expect(
      {for (final kind in FileKind.values) fileKindGlyph(kind).$1},
      hasLength(FileKind.values.length),
    );
    expect(fileKindGlyph(FileKind.folder).$1, Icons.folder);
  });

  testWidgets(
    'fileKindIcon defers to the ambient IconTheme when size is omitted',
    (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: IconTheme(
            data: const IconThemeData(size: 18),
            child: Center(
              child: Builder(
                builder: (context) => fileKindIcon(context, entry('a.txt')),
              ),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(Icon)), const Size(18, 18));
    },
  );
}
