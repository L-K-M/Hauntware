import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show GhostFileKind, GhostFileNodeType, ghostFileKind;
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

  GhostFileKind kindOf(String name) =>
      ghostFileKind(ghostFileItemOf(entry(name)));

  test('extensions map to their family, case-insensitively', () {
    expect(kindOf('IMG_0001.JPG'), GhostFileKind.image);
    expect(kindOf('main.dart'), GhostFileKind.code);
    expect(kindOf('deploy.sh'), GhostFileKind.code);
    expect(kindOf('notes.md'), GhostFileKind.document);
    expect(kindOf('Report.DOCX'), GhostFileKind.document);
    expect(kindOf('site.tar.gz'), GhostFileKind.archive);
    expect(kindOf('manual.pdf'), GhostFileKind.pdf);
    expect(kindOf('talk.mp4'), GhostFileKind.video);
    expect(kindOf('song.flac'), GhostFileKind.audio);
    expect(kindOf('data.bin'), GhostFileKind.other);
  });

  test('dotfiles and bare names have no extension', () {
    expect(kindOf('.bashrc'), GhostFileKind.other);
    expect(kindOf('Makefile'), GhostFileKind.other);
    expect(kindOf('trailing.'), GhostFileKind.other);
    expect(kindOf('.config.json'), GhostFileKind.code);
  });
}
