import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('duplicateServerLabel', () {
    test('a source already named as a copy never gets its own label back', () {
      // Even when the caller did not list the source among the taken
      // labels; the listed variants are pinned further down.
      expect(duplicateServerLabel('web copy', const []), 'web copy 2');
      expect(duplicateServerLabel('copy', const []), 'copy 2');
    });

    test('a hand-doubled suffix does not stutter', () {
      // Stripping only the outermost "copy" leaves "web copy 2", whose first
      // candidate is the taken name it started from — so the duplicate landed
      // on "web copy 2 copy 2", the stutter the parser exists to prevent.
      expect(
        duplicateServerLabel('web copy 2 copy', const ['web copy 2 copy']),
        'web copy',
      );
      // And the documented edges still hold: a server *named* "copy" leaves
      // an empty base and gets numbered rather than stuttering, while a word
      // that merely ends in "copy" is not a suffix at all.
      expect(duplicateServerLabel('copy copy', const ['copy']), 'copy 2');
      expect(duplicateServerLabel('photocopy', const []), 'photocopy copy');
    });

    test('names the first copy and then numbers the rest', () {
      expect(duplicateServerLabel('web', const []), 'web copy');
      // Fills from the front rather than continuing past the highest taken
      // number: with only "web copy 2" in the way, the first copy is still
      // "web copy". Pinned because both rules are defensible and nothing
      // else says which one ships.
      expect(duplicateServerLabel('web', const ['web copy 2']), 'web copy');
      expect(
        duplicateServerLabel('web', const ['web', 'web copy']),
        'web copy 2',
      );
      expect(
        duplicateServerLabel('web', const ['web', 'web copy', 'web copy 2']),
        'web copy 3',
      );
    });

    test('a copy of a copy continues the series instead of stuttering', () {
      // Not "web copy copy": the suffix comes back off before it goes back on.
      expect(
        duplicateServerLabel('web copy', const ['web copy']),
        'web copy 2',
      );
      expect(
        duplicateServerLabel('web copy 2', const ['web copy', 'web copy 2']),
        'web copy 3',
      );
    });

    test('matches taken labels the way the list reads them', () {
      // The server list sorts case-insensitively, so "Web Copy" and "web copy"
      // are one name to the person looking at it.
      expect(duplicateServerLabel('web', const ['WEB COPY']), 'web copy 2');
      // And edge whitespace is not a difference either.
      expect(duplicateServerLabel('web', const ['  web copy  ']), 'web copy 2');
      // The source's own label is matched under the same rules, so a padded
      // or differently-cased source cannot hand back its own name — while
      // the casing the user typed is kept.
      expect(duplicateServerLabel('  WEB COPY ', const []), 'WEB copy 2');
    });

    test('a server named "copy" numbers rather than stutters', () {
      // The whole label is the suffix, so the series just continues.
      expect(duplicateServerLabel('copy', const ['copy']), 'copy 2');
      expect(
        duplicateServerLabel('copy 2', const ['copy', 'copy 2']),
        'copy 3',
      );
      // An unnamed server (nothing enforces a label in the store) is the same
      // shape of input and must not produce a leading-spaced name.
      expect(duplicateServerLabel('', const []), 'copy');
    });

    test('leaves a word that merely starts with "copy" alone', () {
      expect(duplicateServerLabel('copyright', const []), 'copyright copy');
      // A trailing number on its own is not the duplicate series: "web 2" is
      // a name someone chose, so its first copy is "web 2 copy" rather than
      // "web copy" (stripped as if it were one) or "web 3" (continued as one).
      expect(duplicateServerLabel('web 2', const []), 'web 2 copy');
      expect(
        duplicateServerLabel('web 2', const ['web 2', 'web 2 copy']),
        'web 2 copy 2',
      );
    });
  });

  group('duplicateServerConfig', () {
    ServerConfig source({
      String? secretRef,
      bool excludeFromSync = false,
      bool syncSecret = false,
    }) => ServerConfig(
      id: 'original',
      label: 'web',
      host: 'web.example.com',
      port: 2222,
      username: 'deploy',
      authMethod: AuthMethod.privateKey,
      secretRef: secretRef,
      identityFilePath: '/keys/id_ed25519',
      jumpHostId: 'bastion',
      syncSecret: syncSecret,
      group: 'Production',
      color: ServerColor.red,
      customColor: '#123456',
      // All three mark fields carry a non-default value, because the
      // whole-record comparison below only catches a dropped field once the
      // fixture sets one (see its own comment).
      icon: ServerIcon.rocket,
      iconEmoji: '\u{1F433}',
      // A PNG signature plus an IHDR declaring 8x8: the protocol refuses a
      // header without usable dimensions, and a refused value would make
      // this comparison pass by dropping the image on both sides.
      iconImage: 'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAI',
      loginScript: 'tmux attach',
      startDirectory: '~/sites',
      excludeFromSync: excludeFromSync,
      createdAt: 100,
      updatedAt: 200,
    );

    test('takes a new identity and carries the rest over', () {
      final original = source(secretRef: 'sec-old');
      final copy = duplicateServerConfig(
        original,
        id: 'fresh',
        label: 'web copy',
        secretRef: 'sec-new',
        now: 999,
      );

      expect(copy.id, 'fresh');
      expect(copy.label, 'web copy');
      // Never the original's vault entry: deleting either server would strip
      // the credential from the other, and edits would rewrite it in place.
      expect(copy.secretRef, 'sec-new');
      // "Added on" for a copy is today, not the day the original was added.
      expect(copy.createdAt, 999);
      expect(copy.updatedAt, 999);

      expect(copy.host, 'web.example.com');
      expect(copy.port, 2222);
      expect(copy.username, 'deploy');
      expect(copy.authMethod, AuthMethod.privateKey);
      expect(copy.identityFilePath, '/keys/id_ed25519');
      expect(copy.jumpHostId, 'bastion');
      expect(copy.group, 'Production');
      expect(copy.color, ServerColor.red);
      expect(copy.customColor, '#123456');
      // The mark as a whole, not just the glyph: a copy that lost the emoji
      // or the imported image would read as a different server at a glance.
      expect(copy.mark, original.mark);
      // The raw fields too: `mark` resolves a precedence (image over emoji
      // over glyph), so with all three set the comparison above cannot see a
      // copy that dropped the shadowed one.
      expect(copy.iconEmoji, original.iconEmoji);
      expect(copy.iconImage, original.iconImage);
      expect(original.iconEmoji, isNotNull, reason: 'fixture must be valid');
      expect(original.iconImage, isNotNull, reason: 'fixture must be valid');
      expect(copy.icon, ServerIcon.rocket);
      expect(copy.loginScript, 'tmux attach');
      expect(copy.startDirectory, '~/sites');
    });

    test('carries over every field a copy is allowed to share', () {
      // Compared as JSON against the source rather than field by field, so a
      // field added to ServerConfig later fails here — but only once the
      // `source()` fixture above gives it a non-default value, since a field
      // left at its default matches on both sides. Set it there when you add
      // one, or it is silently reset on every copy.
      final original = source(
        secretRef: 'sec-old',
        syncSecret: true,
        excludeFromSync: true,
      );
      final copy = duplicateServerConfig(
        original,
        id: 'fresh',
        label: 'web copy',
        secretRef: 'sec-new',
        now: 999,
      );
      expect(
        copy.toJson(),
        {...original.toJson()}
          ..['id'] = 'fresh'
          ..['label'] = 'web copy'
          ..['secretRef'] = 'sec-new'
          ..['createdAt'] = 999
          ..['updatedAt'] = 999,
      );
    });

    test('a server with no credential copies as one with no credential', () {
      final copy = duplicateServerConfig(
        source(),
        id: 'fresh',
        label: 'web copy',
        secretRef: null,
        now: 999,
      );
      expect(copy.secretRef, isNull);
    });

    test('a null credential never falls back to the source\'s entry', () {
      // Sharing the source's vault entry is the hazard the copy avoids, so
      // an explicit null must win even when the source holds a credential.
      final copy = duplicateServerConfig(
        source(secretRef: 'sec-old'),
        id: 'fresh',
        label: 'web copy',
        secretRef: null,
        now: 999,
      );
      expect(copy.secretRef, isNull);
    });

    test('the sync answers are inherited, never widened', () {
      final copy = duplicateServerConfig(
        source(excludeFromSync: true, syncSecret: false),
        id: 'fresh',
        label: 'web copy',
        secretRef: null,
        now: 999,
      );
      // A copy of a server the user keeps off the sync server starts off it
      // too — the direction that cannot surprise anyone.
      expect(copy.excludeFromSync, isTrue);
      expect(copy.syncSecret, isFalse);
    });
  });
}
