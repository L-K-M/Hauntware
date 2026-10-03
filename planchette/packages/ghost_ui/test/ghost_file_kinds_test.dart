import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/src/family_hues.dart';
import 'package:ghost_ui/src/ghost_file_item.dart';
import 'package:ghost_ui/src/ghost_file_kinds.dart';

GhostFileItem item(
  String name, [
  GhostFileNodeType type = GhostFileNodeType.file,
]) => GhostFileItem(name: name, type: type);

void main() {
  group('ghostFileKind', () {
    test('folders and links classify by node type, never by name', () {
      expect(
        ghostFileKind(item('photos.zip', GhostFileNodeType.directory)),
        GhostFileKind.folder,
      );
      expect(
        ghostFileKind(item('link.png', GhostFileNodeType.symbolicLink)),
        GhostFileKind.link,
      );
      expect(
        ghostFileKind(item('thing.tar', GhostFileNodeType.other)),
        GhostFileKind.archive,
      );
    });

    test('a leading dot is the dotfile stem, not an extension', () {
      expect(ghostFileKind(item('.bashrc')), GhostFileKind.other);
      expect(ghostFileKind(item('.env')), GhostFileKind.other);
      expect(ghostFileKind(item('trailing.')), GhostFileKind.other);
      expect(ghostFileKind(item('noext')), GhostFileKind.other);
    });

    test('extensions match case-insensitively', () {
      expect(ghostFileKind(item('PHOTO.PNG')), GhostFileKind.image);
      expect(ghostFileKind(item('notes.Md')), GhostFileKind.document);
      expect(ghostFileKind(item('ARCHIVE.TAR.GZ')), GhostFileKind.archive);
    });

    test('configuration and scripts classify as code', () {
      for (final name in [
        'app.env',
        'daemon.conf',
        'settings.yaml',
        'build.sh',
        'pubspec.lock',
        'main.dart',
      ]) {
        expect(ghostFileKind(item(name)), GhostFileKind.code, reason: name);
      }
    });

    test('media and document families', () {
      expect(ghostFileKind(item('a.pdf')), GhostFileKind.pdf);
      expect(ghostFileKind(item('song.flac')), GhostFileKind.audio);
      expect(ghostFileKind(item('clip.mkv')), GhostFileKind.video);
      expect(ghostFileKind(item('blob')), GhostFileKind.other);
    });
  });

  group('ghostFileKindGlyph', () {
    test('the glyph/hue table matches the source app', () {
      expect(ghostFileKindGlyph(GhostFileKind.folder), (
        Icons.folder,
        FamilyHue.blue,
      ));
      expect(ghostFileKindGlyph(GhostFileKind.link), (
        Icons.shortcut,
        FamilyHue.cyan,
      ));
      expect(ghostFileKindGlyph(GhostFileKind.image), (
        Icons.image,
        FamilyHue.pink,
      ));
      expect(ghostFileKindGlyph(GhostFileKind.document), (
        Icons.description,
        FamilyHue.graphite,
      ));
      expect(ghostFileKindGlyph(GhostFileKind.code), (
        Icons.integration_instructions,
        FamilyHue.orange,
      ));
      expect(ghostFileKindGlyph(GhostFileKind.archive), (
        Icons.inventory_2,
        FamilyHue.brown,
      ));
      expect(ghostFileKindGlyph(GhostFileKind.pdf), (
        Icons.picture_as_pdf,
        FamilyHue.red,
      ));
      expect(ghostFileKindGlyph(GhostFileKind.audio), (
        Icons.audio_file,
        FamilyHue.purple,
      ));
      expect(ghostFileKindGlyph(GhostFileKind.video), (
        Icons.video_file,
        FamilyHue.purple,
      ));
      expect(ghostFileKindGlyph(GhostFileKind.other), (
        Icons.insert_drive_file,
        FamilyHue.graphite,
      ));
    });
  });
}
