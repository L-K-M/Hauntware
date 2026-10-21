// The picker filter pickServerMarkImage asks for on each platform; the
// picker itself is the platform's and no widget test drives it.
import 'package:file_picker/file_picker.dart' show FileType;
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_marks_picker/ghost_marks_picker.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show kBadgeImageAppleExtensions, kBadgeImageExtensions;

void main() {
  test('desktops name every badge image extension, macOS its own too', () {
    for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
      final filter = serverMarkImageFilter(platform, web: false);
      expect(filter.type, FileType.custom, reason: '$platform');
      expect(filter.extensions, kBadgeImageExtensions, reason: '$platform');
    }
    final mac = serverMarkImageFilter(TargetPlatform.macOS, web: false);
    expect(mac.type, FileType.custom);
    expect(mac.extensions, [
      ...kBadgeImageExtensions,
      ...kBadgeImageAppleExtensions,
    ]);
  });

  test('phones and the web keep the platform image type', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      final filter = serverMarkImageFilter(platform, web: false);
      expect(filter.type, FileType.image, reason: '$platform');
      expect(filter.extensions, isNull, reason: '$platform');
    }
    final web = serverMarkImageFilter(TargetPlatform.linux, web: true);
    expect(web.type, FileType.image);
    expect(web.extensions, isNull);
  });
}
