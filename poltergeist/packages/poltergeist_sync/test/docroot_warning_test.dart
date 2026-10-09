@TestOn('vm')
library;

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

const _identity = EmbeddedHostIdentity(
  host: 'web.example.com',
  port: 22,
  username: 'deploy',
  authMethod: AuthMethod.agent,
);

SyncPair _pair({
  String left = '/home/me/site',
  String right = '/var/www/site',
  SyncRuleSet rules = const SyncRuleSet(),
}) => SyncPair(
  id: 'pair',
  name: 'Site',
  left: LocalEndpoint(left),
  right: RemoteEndpoint(
    server: const BookmarkServerRef(identity: _identity),
    path: right,
  ),
  rules: rules,
);

void main() {
  group('docroot trash warnings', () {
    test('warn every published side that explicit overrides can write', () {
      final warnings = syncDocrootWarnings(
        _pair(left: '/home/me/public_html', right: '/var/www/site'),
      );

      expect(warnings.map((warning) => warning.side), SyncSide.values);
      expect(warnings.last.rootPath, '/var/www/site');
      expect(
        warnings.last.suggestedTrashPath,
        startsWith('~/.poltergeist-trash/site-'),
      );
    });

    test('reverse and additive modes warn their writable sides', () {
      final reverse = syncDocrootWarnings(
        _pair(
          left: '/srv/htdocs/site',
          right: '/home/deploy/source',
          rules: const SyncRuleSet(direction: SyncDirection.rightToLeft),
        ),
      );
      expect(reverse.map((warning) => warning.side), [SyncSide.left]);

      final additive = syncDocrootWarnings(
        _pair(
          left: '/home/me/public_html',
          right: '/srv/www/site',
          rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
        ),
      );
      expect(additive.map((warning) => warning.side), [
        SyncSide.left,
        SyncSide.right,
      ]);
    });

    test('no-delete conflict overrides can still write the source', () {
      final warnings = syncDocrootWarnings(
        _pair(
          left: '/home/me/public_html',
          right: '/home/deploy/source',
          rules: const SyncRuleSet(
            direction: SyncDirection.leftToRight,
            deletions: DeletionPolicy.none,
            backups: BackupPolicy.none,
          ),
        ),
      );

      expect(warnings.map((warning) => warning.side), [SyncSide.left]);
    });

    test('an outside path clears the warning; an inside path does not', () {
      final outside = syncDocrootWarnings(
        _pair(rules: const SyncRuleSet(trashPathRight: '/srv/private/trash')),
      );
      expect(outside, isEmpty);

      final inside = syncDocrootWarnings(
        _pair(rules: const SyncRuleSet(trashPathRight: 'private/trash')),
      );
      expect(inside.map((warning) => warning.side), [SyncSide.right]);
    });

    test('tilde trash stays warned when the root is also tilde-based', () {
      final warnings = syncDocrootWarnings(
        _pair(
          right: '~/public_html',
          rules: const SyncRuleSet(
            trashPathRight: '~/public_html/private/trash',
          ),
        ),
      );

      expect(warnings.map((warning) => warning.side), [SyncSide.right]);
    });

    test('unknown absolute-to-home containment stays warned', () {
      final warnings = syncDocrootWarnings(
        _pair(
          rules: const SyncRuleSet(trashPathRight: '~/.poltergeist-trash/site'),
        ),
      );

      expect(warnings.map((warning) => warning.side), [SyncSide.right]);
    });

    test('resolved home sibling trash clears the warning', () {
      final warnings = syncDocrootWarnings(
        _pair(
          right: '~/public_html',
          rules: const SyncRuleSet(trashPathRight: '~/.poltergeist-trash/site'),
        ),
        resolvedPaths: const {
          SyncSide.right: SyncDocrootPathState(
            rootPath: '/home/deploy/public_html',
            trashPath: '/home/deploy/.poltergeist-trash/site',
            pathStyle: SyncTrashPathStyle.posix,
            pathCase: SyncTrashPathCase.sensitive,
          ),
        },
      );

      expect(warnings, isEmpty);
    });

    test('permanent deletion without backups cannot create trash', () {
      final warnings = syncDocrootWarnings(
        _pair(
          rules: const SyncRuleSet(
            deletions: DeletionPolicy.permanent,
            backups: BackupPolicy.none,
          ),
        ),
      );

      expect(warnings, isEmpty);
    });

    test('no-delete modes can trash explicit kind changes', () {
      final warnings = syncDocrootWarnings(
        _pair(
          rules: const SyncRuleSet(
            deletions: DeletionPolicy.none,
            backups: BackupPolicy.none,
          ),
        ),
      );

      expect(warnings.map((warning) => warning.side), [SyncSide.right]);
      expect(warnings.single.rootPath, '/var/www/site');
    });

    test('matches normalized docroot components but not near misses', () {
      for (final root in ['/srv/PUBLIC_HTML/site/', '/srv/www/./site']) {
        expect(
          syncDocrootWarnings(_pair(right: root)),
          hasLength(1),
          reason: root,
        );
      }

      final windows = syncDocrootWarnings(
        _pair(
          left: r'C:\sites\htdocs\app',
          right: '/home/deploy/source',
          rules: const SyncRuleSet(direction: SyncDirection.rightToLeft),
        ),
      );
      expect(windows.map((warning) => warning.side), [SyncSide.left]);

      for (final root in [
        '/srv/public_html_backup/site',
        '/var/wwwish/site',
        '/srv/www-data/site',
        r'/srv/public_html\archive/site',
      ]) {
        expect(syncDocrootWarnings(_pair(right: root)), isEmpty, reason: root);
      }
    });

    test('absolute paths suppress only when outside the root', () {
      final inside = syncDocrootWarnings(
        _pair(
          rules: const SyncRuleSet(
            trashPathRight: '/var/www/site/private/trash',
          ),
        ),
      );
      final sibling = syncDocrootWarnings(
        _pair(
          rules: const SyncRuleSet(
            trashPathRight: '/var/www/site-backups/trash',
          ),
        ),
      );

      expect(inside, hasLength(1));
      expect(sibling, isEmpty);
    });

    test('lexical case aliases stay warned until scan resolves them', () {
      final warnings = syncDocrootWarnings(
        _pair(
          rules: const SyncRuleSet(
            trashPathRight: '/VAR/WWW/site/private/trash',
          ),
        ),
      );

      expect(warnings, hasLength(1));
    });

    test('resolved paths override unsafe lexical aliases', () {
      final warnings = syncDocrootWarnings(
        _pair(rules: const SyncRuleSet(trashPathRight: '/srv/private/trash')),
        resolvedPaths: const {
          SyncSide.right: SyncDocrootPathState(
            rootPath: '/var/www/site',
            trashPath: '/var/www/site/private/trash',
            pathStyle: SyncTrashPathStyle.posix,
            pathCase: SyncTrashPathCase.sensitive,
          ),
        },
      );

      expect(warnings.map((warning) => warning.side), [SyncSide.right]);
      expect(warnings.single.rootPath, '/var/www/site');
    });

    test('canonical roots survive unresolved trash identity', () {
      final warnings = syncDocrootWarnings(
        _pair(right: '.'),
        resolvedPaths: const {
          SyncSide.right: SyncDocrootPathState(
            rootPath: '/var/www/site',
            trashPath: null,
            pathStyle: SyncTrashPathStyle.posix,
            pathCase: SyncTrashPathCase.sensitive,
          ),
        },
      );

      expect(warnings.map((warning) => warning.side), [SyncSide.right]);
      expect(warnings.single.rootPath, '/var/www/site');
    });

    test('canonical containment uses the scanned root case rule', () {
      final warnings = syncDocrootWarnings(
        _pair(
          rules: const SyncRuleSet(
            trashPathRight: '/VAR/WWW/SITE/private/trash',
          ),
        ),
        resolvedPaths: const {
          SyncSide.right: SyncDocrootPathState(
            rootPath: '/var/www/site',
            trashPath: '/VAR/WWW/SITE/private/trash',
            pathStyle: SyncTrashPathStyle.posix,
            pathCase: SyncTrashPathCase.insensitive,
          ),
        },
      );

      expect(warnings.map((warning) => warning.side), [SyncSide.right]);
    });

    test('suggestions stay distinct for same-named roots', () {
      final first = syncDocrootWarnings(
        _pair(right: '/var/www/site'),
      ).single.suggestedTrashPath;
      final second = syncDocrootWarnings(
        _pair(right: '/srv/www/site'),
      ).single.suggestedTrashPath;

      expect(first, isNot(second));
      expect(first.split('/').last.length, lessThanOrEqualTo(63));
    });

    test('suggestions keep the full digest when prefixes collide', () {
      final first = syncDocrootWarnings(
        _pair(right: '/var/www/841774/site'),
      ).single.suggestedTrashPath;
      final second = syncDocrootWarnings(
        _pair(right: '/var/www/2726146/site'),
      ).single.suggestedTrashPath;

      expect(first, isNot(second));
      expect(first.split('/').last.length, lessThanOrEqualTo(63));
      expect(second.split('/').last.length, lessThanOrEqualTo(63));
      expect(first.split('-').last, matches(RegExp(r'^[a-z2-7]{52}$')));
      expect(second.split('-').last, matches(RegExp(r'^[a-z2-7]{52}$')));
    });
  });
}
