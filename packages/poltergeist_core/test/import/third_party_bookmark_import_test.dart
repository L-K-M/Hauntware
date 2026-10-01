import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

ThirdPartyBookmarkImportFile _textFile(String name, String text) =>
    ThirdPartyBookmarkImportFile(name, utf8.encode(text));

ThirdPartyBookmarkImportFile _utf16LeFile(String name, String text) {
  final bytes = <int>[0xFF, 0xFE];
  for (final codeUnit in text.codeUnits) {
    bytes
      ..add(codeUnit & 0xFF)
      ..add(codeUnit >> 8);
  }
  return ThirdPartyBookmarkImportFile(name, bytes);
}

ThirdPartyBookmarkImportService _service() {
  var nextId = 0;
  return ThirdPartyBookmarkImportService(mintId: () => 'import-${nextId++}');
}

ThirdPartyBookmarkImportPreview _load(
  ThirdPartyBookmarkFormat format,
  Iterable<ThirdPartyBookmarkImportFile> files, {
  Iterable<Bookmark> existingBookmarks = const [],
}) => _service().loadPreview(
  format: format,
  files: files,
  existingBookmarks: existingBookmarks,
);

Bookmark _bookmark(
  String label, {
  required String host,
  int port = 22,
  String username = '',
  String remotePath = '/',
  String? sortKey,
}) {
  final now = DateTime.utc(2026, 10, 1);
  return Bookmark(
    id: 'existing-$label',
    kind: BookmarkKind.remotePath,
    label: label,
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: host,
        port: port,
        username: username,
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: remotePath,
    sortKey: sortKey ?? label,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('FileZilla', () {
    test('imports nested SFTP key sites and safe remote paths', () {
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('sitemanager.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<FileZilla3 platform="windows">
  <Servers>
    <Folder expanded="1">Production
      <Folder expanded="1">Europe
        <Server>
          <Host>sftp.example.com</Host>
          <Port>2222</Port>
          <Protocol>1</Protocol>
          <User>deploy</User>
          <Pass encoding="base64">bmV2ZXItaW1wb3J0</Pass>
          <Logontype>5</Logontype>
          <Keyfile>C:\\Users\\alice\\id key</Keyfile>
          <Name>Primary</Name>
          <RemoteDir>1 0 4 home 9 team docs</RemoteDir>
        </Server>
      </Folder>
    </Folder>
  </Servers>
</FileZilla3>
'''),
      ]);

      final row = preview.rows.single;
      expect(row.id, 'import-0');
      expect(row.label, 'Production/Europe/Primary');
      expect(row.host, 'sftp.example.com');
      expect(row.port, 2222);
      expect(row.username, 'deploy');
      expect(row.protocol, 'SFTP');
      expect(row.authMethod, AuthMethod.privateKey);
      expect(row.identityFilePath, r'C:\Users\alice\id key');
      expect(row.remotePath, '/home/team docs');
      expect(row.issues, isEmpty);
      expect(row.importByDefault, isTrue);

      final now = DateTime.utc(2026, 10, 1);
      final bookmark = row.toBookmark(now: now);
      expect(bookmark.label, row.label);
      expect(bookmark.remotePath, '/home/team docs');
      expect(isValidSortKey(bookmark.sortKey), isTrue);
      expect(bookmark.server!.identity!.identityFilePath, row.identityFilePath);
      expect(bookmark.server!.identity!.authMethod, AuthMethod.privateKey);
    });

    test('imports child bookmarks with inherited server fields', () {
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('sitemanager.xml', '''
<FileZilla3 platform="*nix"><Servers><Folder>Production
  <Server>
    <Host>files.example.com</Host><Port>2022</Port><Protocol>1</Protocol>
    <User>deploy</User><Logontype>5</Logontype>
    <Keyfile>/keys/id_ed25519</Keyfile><Name>Primary</Name>
    <RemoteDir>1 0 4 home</RemoteDir>
    <Bookmark><Name>Logs</Name><RemoteDir>1 0 3 var 3 log</RemoteDir></Bookmark>
    <Bookmark><Name>Broken</Name><RemoteDir>relative</RemoteDir></Bookmark>
    <Bookmark><Name>Logs duplicate</Name>
      <RemoteDir>1 0 3 var 3 log</RemoteDir></Bookmark>
    <Bookmark><Name>Inherited missing</Name></Bookmark>
    <Bookmark><Name>Inherited empty</Name><RemoteDir></RemoteDir></Bookmark>
    <Bookmark><Name>Inherited whitespace</Name><RemoteDir>   </RemoteDir></Bookmark>
  </Server>
</Folder></Servers></FileZilla3>
'''),
      ]);

      expect(preview.rows.map((row) => row.label), [
        'Production/Primary',
        'Production/Primary/Logs',
        'Production/Primary/Broken',
        'Production/Primary/Logs duplicate',
        'Production/Primary/Inherited missing',
        'Production/Primary/Inherited empty',
        'Production/Primary/Inherited whitespace',
      ]);
      expect(preview.rows.map((row) => row.remotePath), [
        '/home',
        '/var/log',
        '/',
        '/var/log',
        '/home',
        '/home',
        '/home',
      ]);
      for (final row in preview.rows) {
        expect(row.host, 'files.example.com');
        expect(row.port, 2022);
        expect(row.username, 'deploy');
        expect(row.authMethod, AuthMethod.privateKey);
        expect(row.identityFilePath, '/keys/id_ed25519');
      }
      expect(preview.rows[1].matchesEarlierImportRow, isFalse);
      expect(preview.rows[1].importByDefault, isTrue);
      expect(
        preview.rows[2].issues,
        contains(ThirdPartyBookmarkImportIssue.invalidRemotePath),
      );
      expect(preview.rows[3].matchesEarlierImportRow, isTrue);
      expect(preview.rows[3].earlierImportRowLabel, 'Production/Primary/Logs');
      expect(preview.rows[3].importByDefault, isFalse);
      for (final row in preview.rows.skip(4)) {
        expect(row.matchesEarlierImportRow, isTrue);
        expect(row.earlierImportRowLabel, 'Production/Primary');
        expect(row.importByDefault, isFalse);
      }
    });

    test('child without a path inherits the server path issue', () {
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('sitemanager.xml', '''
<FileZilla3><Servers><Server>
  <Host>files.example.com</Host><Protocol>1</Protocol><Name>Primary</Name>
  <RemoteDir>relative</RemoteDir>
  <Bookmark><Name>Inherited</Name></Bookmark>
</Server></Servers></FileZilla3>
'''),
      ]);

      expect(preview.rows.map((row) => row.remotePath), ['/', '/']);
      for (final row in preview.rows) {
        expect(
          row.issues,
          contains(ThirdPartyBookmarkImportIssue.invalidRemotePath),
        );
      }
      expect(preview.rows[1].matchesEarlierImportRow, isTrue);
      expect(preview.rows[1].earlierImportRowLabel, 'Primary');
    });

    test('child path override drops oversized server-path issues', () {
      final oversizedServerPath = '/${'x' * 8192}';
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('sitemanager.xml', '''
<FileZilla3><Servers><Server>
  <Host>files.example.com</Host><Protocol>1</Protocol><Name>Primary</Name>
  <RemoteDir>$oversizedServerPath</RemoteDir>
  <Bookmark><Name>Valid child</Name><RemoteDir>/valid</RemoteDir></Bookmark>
</Server></Servers></FileZilla3>
'''),
      ]);

      expect(
        preview.rows.first.issues,
        contains(ThirdPartyBookmarkImportIssue.fieldTooLong),
      );
      final child = preview.rows.last;
      expect(child.remotePath, '/valid');
      expect(
        child.issues,
        isNot(contains(ThirdPartyBookmarkImportIssue.fieldTooLong)),
      );
      expect(child.importable, isTrue);
      expect(child.importByDefault, isTrue);
    });

    test('uses platform character units for Unicode safe paths', () {
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('linux.xml', '''
<FileZilla3 platform="*nix"><Servers><Server>
  <Host>linux.example.com</Host><Protocol>1</Protocol><Logontype>2</Logontype>
  <Name>Linux</Name><RemoteDir>1 0 1 😀 4 docs</RemoteDir>
</Server></Servers></FileZilla3>
'''),
        _textFile('windows.xml', '''
<FileZilla3 platform="windows"><Servers><Server>
  <Host>windows.example.com</Host><Protocol>1</Protocol><Logontype>2</Logontype>
  <Name>Windows</Name><RemoteDir>1 0 2 😀 4 docs</RemoteDir>
</Server></Servers></FileZilla3>
'''),
      ]);

      expect(preview.rows.map((row) => row.remotePath), [
        '/😀/docs',
        '/😀/docs',
      ]);
    });

    test('preserves trailing spaces in server and child safe paths', () {
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('spaces.xml', '''
<FileZilla3 platform="*nix"><Servers><Server>
  <Host>files.example.com</Host><Protocol>1</Protocol><Name>Spaces</Name>
  <Logontype>5</Logontype><Keyfile>/keys/id </Keyfile>
  <RemoteDir>1 0 4 home 5 logs </RemoteDir>
  <Bookmark><Name>Child</Name>
    <RemoteDir>1 0 3 var 4 tmp </RemoteDir></Bookmark>
</Server></Servers></FileZilla3>
'''),
      ]);

      expect(preview.rows.map((row) => row.remotePath), [
        '/home/logs ',
        '/var/tmp ',
      ]);
      for (final row in preview.rows) {
        expect(row.identityFilePath, '/keys/id ');
        expect(
          row.issues,
          isNot(contains(ThirdPartyBookmarkImportIssue.invalidRemotePath)),
        );
      }
    });

    test('rejects non-Unix safe path prefixes', () {
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('sitemanager.xml', '''
<FileZilla3><Servers><Server>
  <Host>files.example.com</Host><Protocol>1</Protocol>
  <RemoteDir>2 2 C: 4 data</RemoteDir>
</Server></Servers></FileZilla3>
'''),
      ]);

      expect(preview.rows.single.remotePath, '/');
      expect(
        preview.rows.single.issues,
        contains(ThirdPartyBookmarkImportIssue.invalidRemotePath),
      );
    });

    test('does not use a key outside key-file logon mode', () {
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('sitemanager.xml', '''
<FileZilla3><Servers><Server>
  <Host>password.example.com</Host><Port>22</Port><Protocol>1</Protocol>
  <User>alice</User><Pass encoding="base64">c2VjcmV0</Pass>
  <Logontype>1</Logontype><Keyfile>/stale/key</Keyfile><Name>Password</Name>
</Server></Servers></FileZilla3>
'''),
      ]);

      final row = preview.rows.single;
      expect(row.authMethod, AuthMethod.password);
      expect(row.identityFilePath, isNull);
      expect(
        row.issues,
        contains(ThirdPartyBookmarkImportIssue.credentialsNotImported),
      );
      expect(
        row.toBookmark(now: DateTime.utc(2026)).server!.identity!.secretRef,
        isNull,
      );
    });

    test('keeps unsupported and malformed entries visible but disabled', () {
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('sitemanager.xml', '''
<FileZilla3><Servers>
  <Server><Host>ftp.example.com</Host><Port>21</Port><Protocol>0</Protocol>
    <Name>FTP only</Name></Server>
  <Server><Port>70000</Port><Protocol>1</Protocol><Name>Broken</Name>
    <RemoteDir>1 0 9 short</RemoteDir></Server>
</Servers></FileZilla3>
'''),
      ]);

      expect(preview.rows, hasLength(2));
      expect(
        preview.rows[0].issues,
        contains(ThirdPartyBookmarkImportIssue.unsupportedProtocol),
      );
      expect(preview.rows[0].importable, isFalse);
      expect(
        preview.rows[1].issues,
        containsAll([
          ThirdPartyBookmarkImportIssue.invalidPort,
          ThirdPartyBookmarkImportIssue.missingHost,
          ThirdPartyBookmarkImportIssue.invalidRemotePath,
        ]),
      );
      expect(preview.rows[1].remotePath, '/');
      expect(preview.rows[1].importable, isFalse);
    });

    test('returns technical protocol tokens without UI copy', () {
      final fileZilla = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('unknown.xml', '''
<FileZilla3><Servers><Server><Host>files.example.com</Host>
  <Protocol>99</Protocol></Server></Servers></FileZilla3>
'''),
      ]);
      final cyberduck = _load(ThirdPartyBookmarkFormat.cyberduck, [
        _textFile('missing.duck', '''
<plist><dict><key>Hostname</key><string>files.example.com</string></dict></plist>
'''),
      ]);

      expect(fileZilla.rows.single.protocol, '99');
      expect(
        fileZilla.rows.single.protocolVerdict,
        ThirdPartyBookmarkProtocolVerdict.unknown,
      );
      expect(cyberduck.rows.single.protocol, isEmpty);
      expect(
        cyberduck.rows.single.protocolVerdict,
        ThirdPartyBookmarkProtocolVerdict.unknown,
      );
    });
  });

  group('WinSCP', () {
    test('unmunges Unicode sessions and imports SFTP fields', () {
      final preview = _load(ThirdPartyBookmarkFormat.winScp, [
        _textFile('WinSCP.ini', '''
[Sessions\\Default%20Settings]
FSProtocol=1

[Sessions\\%EF%BB%BFZ%C3%BCrich]
HostName=deploy@files.example.com
PortNumber=2200
UserName=ignored-by-host-prefix
PublicKeyFile=%EF%BB%BF%C3%BCsers%5Calice%5Cid_ed25519
FSProtocol=2
RemoteDirectory=%2Fdata%2Fteam
PasswordPlain=never-import
'''),
      ]);

      final row = preview.rows.single;
      expect(row.label, 'Zürich');
      expect(row.host, 'files.example.com');
      expect(row.port, 2200);
      expect(row.username, 'deploy');
      expect(row.identityFilePath, r'üsers\alice\id_ed25519');
      expect(row.authMethod, AuthMethod.privateKey);
      expect(row.remotePath, '/data/team');
      expect(row.issues, isEmpty);
    });

    test('reads UTF-16 BOM and keeps password credentials out', () {
      final preview = _load(ThirdPartyBookmarkFormat.winScp, [
        _utf16LeFile('WinSCP.ini', '''
[Sessions\\Password%20site]
HostName=password.example.com
UserName=alice
Password=%EF%BB%BF%C3
PasswordPlain=%GG%not-even-an-escape
FSProtocol=1
'''),
      ]);

      final row = preview.rows.single;
      expect(row.label, 'Password site');
      expect(row.authMethod, AuthMethod.password);
      expect(row.identityFilePath, isNull);
      expect(row.host, 'password.example.com');
      expect(
        row.issues,
        contains(ThirdPartyBookmarkImportIssue.credentialsNotImported),
      );
    });

    test('shows unsupported protocols and route loss', () {
      final preview = _load(ThirdPartyBookmarkFormat.winScp, [
        _textFile('WinSCP.ini', '''
[Sessions\\SCP]
HostName=same.example.com
UserName=alice
FSProtocol=0

[Sessions\\Tunneled]
HostName=same.example.com
UserName=alice
FSProtocol=1
Tunnel=1

[Sessions\\Proxied]
HostName=proxy.example.com
FSProtocol=1
ProxyMethod=SOCKS5
'''),
      ]);

      expect(preview.rows, hasLength(3));
      expect(
        preview.rows[0].issues,
        contains(ThirdPartyBookmarkImportIssue.unsupportedProtocol),
      );
      // The disabled SCP row does not claim the valid SFTP row's endpoint.
      expect(preview.rows[1].matchesEarlierImportRow, isFalse);
      expect(preview.rows[1].importable, isTrue);
      expect(preview.rows[1].importByDefault, isFalse);
      expect(
        preview.rows[1].issues,
        contains(ThirdPartyBookmarkImportIssue.routeNotImported),
      );
      expect(
        preview.rows[2].issues,
        contains(ThirdPartyBookmarkImportIssue.routeNotImported),
      );
    });

    test('route loss does not suppress a later direct session', () {
      final preview = _load(ThirdPartyBookmarkFormat.winScp, [
        _textFile('WinSCP.ini', '''
[Sessions\\Tunneled]
HostName=files.example.com
UserName=deploy
FSProtocol=1
RemoteDirectory=%2Fsrv
Tunnel=1

[Sessions\\Direct]
HostName=FILES.EXAMPLE.COM
UserName=deploy
FSProtocol=1
RemoteDirectory=%2Fsrv
'''),
      ]);

      expect(preview.rows[0].importByDefault, isFalse);
      expect(
        preview.rows[0].issues,
        contains(ThirdPartyBookmarkImportIssue.routeNotImported),
      );
      expect(preview.rows[1].matchesEarlierImportRow, isFalse);
      expect(preview.rows[1].importByDefault, isTrue);
    });

    test('invalid relative remote paths fall back to root', () {
      final preview = _load(ThirdPartyBookmarkFormat.winScp, [
        _textFile('WinSCP.ini', '''
[Sessions\\Relative]
HostName=files.example.com
FSProtocol=1
RemoteDirectory=home%2Falice
'''),
      ]);

      expect(preview.rows.single.remotePath, '/');
      expect(
        preview.rows.single.issues,
        contains(ThirdPartyBookmarkImportIssue.invalidRemotePath),
      );
    });

    test('NUL-bearing remote paths fall back to root', () {
      final preview = _load(ThirdPartyBookmarkFormat.winScp, [
        _textFile('WinSCP.ini', '''
[Sessions\\Nul]
HostName=files.example.com
FSProtocol=1
RemoteDirectory=/home\u0000elsewhere
'''),
      ]);

      expect(preview.rows.single.remotePath, '/');
      expect(
        preview.rows.single.issues,
        contains(ThirdPartyBookmarkImportIssue.invalidRemotePath),
      );
    });

    test('disables and sanitizes control-bearing identity paths', () {
      final preview = _load(ThirdPartyBookmarkFormat.winScp, [
        _textFile('WinSCP.ini', r'''
[Sessions\Control key]
HostName=files.example.com
PublicKeyFile=C:%5Ckeys%5Cid%00key
FSProtocol=1
'''),
      ]);

      final row = preview.rows.single;
      expect(row.identityFilePath, isNot(contains('\u0000')));
      expect(
        row.issues,
        contains(ThirdPartyBookmarkImportIssue.invalidFieldValue),
      );
      expect(row.importable, isFalse);
    });
  });

  group('Cyberduck', () {
    test('accepts the standard plist doctype and current key dictionary', () {
      final preview = _load(ThirdPartyBookmarkFormat.cyberduck, [
        _textFile('production.duck', '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Protocol</key><string>sftp</string>
  <key>Hostname</key><string>duck.example.com</string>
  <key>Port</key><integer>2022</integer>
  <key>Username</key><string>alice</string>
  <key>Path</key><string>/srv/files</string>
  <key>Nickname</key><string>Production Duck</string>
  <key>Private Key File</key><string>/legacy/key</string>
  <key>Private Key File Dictionary</key><dict>
    <key>Path</key><string>~/.ssh/id_ed25519</string>
  </dict>
</dict></plist>
'''),
      ]);

      final row = preview.rows.single;
      expect(row.label, 'Production Duck');
      expect(row.host, 'duck.example.com');
      expect(row.port, 2022);
      expect(row.username, 'alice');
      expect(row.protocol, 'SFTP');
      expect(row.identityFilePath, '~/.ssh/id_ed25519');
      expect(row.remotePath, '/srv/files');
      expect(row.issues, isEmpty);
    });

    test('supports legacy keys and password-only bookmarks', () {
      final preview = _load(ThirdPartyBookmarkFormat.cyberduck, [
        _textFile('legacy.duck', '''
<plist><dict>
  <key>Protocol</key><string>sftp</string>
  <key>Hostname</key><string>legacy.example.com</string>
  <key>Private Key File</key><string>/keys/legacy.pem</string>
</dict></plist>
'''),
        _textFile('password.duck', '''
<plist><dict>
  <key>Protocol</key><string>sftp</string>
  <key>Hostname</key><string>password.example.com</string>
</dict></plist>
'''),
        _textFile('fallback.duck', '''
<plist><dict>
  <key>Protocol</key><string>sftp</string>
  <key>Hostname</key><string>fallback.example.com</string>
  <key>Private Key File</key><string>/keys/fallback.pem</string>
  <key>Private Key File Dictionary</key><dict>
    <key>Path</key><false/>
  </dict>
</dict></plist>
'''),
      ]);

      expect(preview.rows[0].identityFilePath, '/keys/legacy.pem');
      expect(preview.rows[0].authMethod, AuthMethod.privateKey);
      expect(preview.rows[1].label, 'password.example.com');
      expect(preview.rows[1].authMethod, AuthMethod.password);
      expect(
        preview.rows[1].issues,
        contains(ThirdPartyBookmarkImportIssue.credentialsNotImported),
      );
      expect(preview.rows[2].identityFilePath, '/keys/fallback.pem');
      expect(preview.rows[2].authMethod, AuthMethod.privateKey);
    });

    test('empty current key falls back without trimming nonempty keys', () {
      final preview = _load(ThirdPartyBookmarkFormat.cyberduck, [
        _textFile('empty-current.duck', '''
<plist><dict>
  <key>Protocol</key><string>sftp</string>
  <key>Hostname</key><string>empty.example.com</string>
  <key>Private Key File</key><string>/keys/legacy.pem</string>
  <key>Private Key File Dictionary</key><dict>
    <key>Path</key><string></string>
  </dict>
</dict></plist>
'''),
        _textFile('spaced-current.duck', '''
<plist><dict>
  <key>Protocol</key><string>sftp</string>
  <key>Hostname</key><string>spaced.example.com</string>
  <key>Private Key File</key><string>/keys/legacy.pem</string>
  <key>Private Key File Dictionary</key><dict>
    <key>Path</key><string> /keys/current.pem </string>
  </dict>
</dict></plist>
'''),
        _textFile('blank-current.duck', '''
<plist><dict>
  <key>Protocol</key><string>sftp</string>
  <key>Hostname</key><string>blank.example.com</string>
  <key>Private Key File</key><string>/keys/blank-fallback.pem</string>
  <key>Private Key File Dictionary</key><dict>
    <key>Path</key><string>   </string>
  </dict>
</dict></plist>
'''),
      ]);

      expect(preview.rows[0].identityFilePath, '/keys/legacy.pem');
      expect(preview.rows[0].authMethod, AuthMethod.privateKey);
      expect(preview.rows[1].identityFilePath, ' /keys/current.pem ');
      expect(preview.rows[1].authMethod, AuthMethod.privateKey);
      expect(preview.rows[2].identityFilePath, '/keys/blank-fallback.pem');
      expect(preview.rows[2].authMethod, AuthMethod.privateKey);
    });

    test('keeps unsupported and malformed bookmarks visible', () {
      final preview = _load(ThirdPartyBookmarkFormat.cyberduck, [
        _textFile('broken.duck', '''
<plist><dict>
  <key>Protocol</key><string>ftp</string>
  <key>Port</key><integer>not-a-port</integer>
  <key>Path</key><string>relative/path</string>
</dict></plist>
'''),
      ]);

      final row = preview.rows.single;
      expect(row.label, 'broken.duck');
      expect(row.importable, isFalse);
      expect(
        row.issues,
        containsAll([
          ThirdPartyBookmarkImportIssue.unsupportedProtocol,
          ThirdPartyBookmarkImportIssue.invalidPort,
          ThirdPartyBookmarkImportIssue.missingHost,
          ThirdPartyBookmarkImportIssue.invalidRemotePath,
        ]),
      );
    });
  });

  group('common safety and dedupe', () {
    test('dedupes endpoint and remote path together', () {
      final preview = _load(
        ThirdPartyBookmarkFormat.cyberduck,
        [
          _textFile('existing.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>files.example.com</string>
<key>Username</key><string>deploy</string>
<key>Path</key><string>/existing</string></dict></plist>
'''),
          _textFile('distinct.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>files.example.com</string>
<key>Username</key><string>deploy</string>
<key>Path</key><string>/distinct</string></dict></plist>
'''),
          _textFile('duplicate.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>FILES.EXAMPLE.COM</string>
<key>Username</key><string>deploy</string>
<key>Path</key><string>/distinct</string></dict></plist>
'''),
        ],
        existingBookmarks: [
          _bookmark(
            'Existing path',
            host: 'files.example.com',
            username: 'deploy',
            remotePath: '/existing',
          ),
        ],
      );

      expect(preview.rows[0].matchesExistingBookmark, isTrue);
      expect(preview.rows[0].importByDefault, isFalse);
      expect(preview.rows[1].matchesExistingBookmark, isFalse);
      expect(preview.rows[1].matchesEarlierImportRow, isFalse);
      expect(preview.rows[1].importByDefault, isTrue);
      expect(preview.rows[2].matchesEarlierImportRow, isTrue);
      expect(preview.rows[2].earlierImportRowLabel, 'files.example.com');
      expect(preview.rows[2].importByDefault, isFalse);
    });

    test('dedupes existing endpoints and prior files case-insensitively', () {
      final preview = _load(
        ThirdPartyBookmarkFormat.cyberduck,
        [
          _textFile('existing.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>EXISTING.example.com</string>
<key>Username</key><string>alice</string></dict></plist>
'''),
          _textFile('first.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>new.example.com</string>
<key>Username</key><string>deploy</string></dict></plist>
'''),
          _textFile('second.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>NEW.EXAMPLE.COM</string>
<key>Username</key><string>deploy</string></dict></plist>
'''),
        ],
        existingBookmarks: [
          _bookmark(
            'Existing bookmark',
            host: 'existing.example.com',
            username: 'alice',
          ),
        ],
      );

      expect(preview.rows[0].matchesExistingBookmark, isTrue);
      expect(preview.rows[0].existingBookmarkLabel, 'Existing bookmark');
      expect(preview.rows[0].importByDefault, isFalse);
      expect(preview.rows[1].matchesEarlierImportRow, isFalse);
      expect(preview.rows[2].matchesEarlierImportRow, isTrue);
      expect(preview.rows[2].earlierImportRowLabel, 'new.example.com');
      expect(preview.rows[2].importByDefault, isFalse);
    });

    test('copies selected bytes before parsing', () {
      final bytes = utf8.encode('''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>stable.example.com</string></dict></plist>
''');
      final file = ThirdPartyBookmarkImportFile('stable.duck', bytes);
      bytes.fillRange(0, bytes.length, 0);

      final preview = _load(ThirdPartyBookmarkFormat.cyberduck, [file]);
      expect(preview.rows.single.host, 'stable.example.com');
      expect(() => file.bytes[0] = 0, throwsUnsupportedError);
    });

    test('bounds and sanitizes source names at construction', () {
      const oversizedNameLength = 8192;
      const maximumExpectedNameLength = 512;
      final unsafeName = '\u0000${'x' * oversizedNameLength}';
      final file = ThirdPartyBookmarkImportFile(unsafeName, const []);
      final unnamed = ThirdPartyBookmarkImportFile('\t\n', const []);
      final controlsOnly = ThirdPartyBookmarkImportFile(
        '\u0000\u007F',
        const [],
      );

      expect(file.name.length, lessThanOrEqualTo(maximumExpectedNameLength));
      expect(file.name, isNot(contains('\u0000')));
      expect(file.name, ThirdPartyBookmarkImportFile.normalizeName(unsafeName));
      expect(unnamed.name, '?');
      expect(controlsOnly.name, '?');
    });

    test('sanitizes bidi and line-separator controls in display fields', () {
      const unsafeControls =
          '\u061C\u200E\u200F\u202A\u202B\u202C\u202D\u202E'
          '\u2066\u2067\u2068\u2069\u2028\u2029';
      const expectedLabelLimit = 512;
      const expectedHostLimit = 1024;
      final label = 'site$unsafeControls${'l' * 600}';
      final host = 'files$unsafeControls${'h' * 1100}.example.com';
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('unsafe-display.xml', '''
<FileZilla3><Servers><Server>
  <Host>$host</Host><Protocol>1</Protocol><Name>$label</Name>
</Server></Servers></FileZilla3>
'''),
      ]);

      final row = preview.rows.single;
      expect(row.label.length, expectedLabelLimit);
      expect(row.host.length, expectedHostLimit);
      expect(row.label, contains('\uFFFD'));
      expect(row.host, contains('\uFFFD'));
      for (final rune in unsafeControls.runes) {
        final control = String.fromCharCode(rune);
        expect(row.label, isNot(contains(control)));
        expect(row.host, isNot(contains(control)));
      }
      expect(
        row.issues,
        containsAll([
          ThirdPartyBookmarkImportIssue.fieldTooLong,
          ThirdPartyBookmarkImportIssue.invalidFieldValue,
        ]),
      );
      expect(row.importable, isFalse);
    });

    test('rejects XML entity declarations before parsing', () {
      final file = _textFile('unsafe.duck', '''
<!DOCTYPE plist [<!ENTITY secret SYSTEM "file:///etc/passwd">]>
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>&secret;</string></dict></plist>
''');

      expect(
        () => _load(ThirdPartyBookmarkFormat.cyberduck, [file]),
        throwsA(
          isA<ThirdPartyBookmarkImportException>().having(
            (error) => error.failure,
            'failure',
            ThirdPartyBookmarkImportFailure.unsafeXml,
          ),
        ),
      );
    });

    test('reports malformed XML and invalid byte encoding', () {
      expect(
        () => _load(ThirdPartyBookmarkFormat.fileZilla, [
          _textFile('broken.xml', '<FileZilla3><Servers>'),
        ]),
        throwsA(
          isA<ThirdPartyBookmarkImportException>().having(
            (error) => error.failure,
            'failure',
            ThirdPartyBookmarkImportFailure.malformedSource,
          ),
        ),
      );
      expect(
        () => _load(ThirdPartyBookmarkFormat.winScp, [
          ThirdPartyBookmarkImportFile('broken.ini', const [0xFF]),
        ]),
        throwsA(
          isA<ThirdPartyBookmarkImportException>().having(
            (error) => error.failure,
            'failure',
            ThirdPartyBookmarkImportFailure.invalidEncoding,
          ),
        ),
      );
      expect(
        () => _load(ThirdPartyBookmarkFormat.winScp, [
          _textFile('bad-unicode.ini', '''
[Sessions\\%EF%BB%BF%C3]
HostName=files.example.com
'''),
        ]),
        throwsA(
          isA<ThirdPartyBookmarkImportException>().having(
            (error) => error.failure,
            'failure',
            ThirdPartyBookmarkImportFailure.malformedSource,
          ),
        ),
      );
    });

    test('rejects file-count and per-file byte bounds', () {
      expect(
        () => _load(
          ThirdPartyBookmarkFormat.cyberduck,
          Iterable.generate(
            thirdPartyBookmarkImportMaxFiles + 1,
            (index) => ThirdPartyBookmarkImportFile('$index.duck', const []),
          ),
        ),
        throwsA(
          isA<ThirdPartyBookmarkImportException>().having(
            (error) => error.failure,
            'failure',
            ThirdPartyBookmarkImportFailure.tooManyFiles,
          ),
        ),
      );
      expect(
        () => _load(ThirdPartyBookmarkFormat.cyberduck, [
          ThirdPartyBookmarkImportFile(
            'large.duck',
            List.filled(thirdPartyBookmarkImportMaxFileBytes + 1, 0),
          ),
        ]),
        throwsA(
          isA<ThirdPartyBookmarkImportException>().having(
            (error) => error.failure,
            'failure',
            ThirdPartyBookmarkImportFailure.fileTooLarge,
          ),
        ),
      );
    });

    test('rejects aggregate bytes across individually valid files', () {
      final maximumSizedBytes = List<int>.filled(
        thirdPartyBookmarkImportMaxFileBytes,
        0,
        growable: false,
      );
      final files = [
        for (var index = 0; index < 4; index++)
          ThirdPartyBookmarkImportFile('$index.duck', maximumSizedBytes),
        ThirdPartyBookmarkImportFile('overflow.duck', const [0]),
      ];

      expect(
        () => _load(ThirdPartyBookmarkFormat.cyberduck, files),
        throwsA(
          isA<ThirdPartyBookmarkImportException>().having(
            (error) => error.failure,
            'failure',
            ThirdPartyBookmarkImportFailure.totalSizeExceeded,
          ),
        ),
      );
    });

    test('stops a single source at the row bound', () {
      const server = '''
<Server><Host>files.example.com</Host><Protocol>1</Protocol></Server>
''';
      final file = _textFile(
        'too-many.xml',
        '<FileZilla3><Servers>'
            '${List.filled(thirdPartyBookmarkImportMaxRows + 1, server).join()}'
            '</Servers></FileZilla3>',
      );

      expect(
        () => _load(ThirdPartyBookmarkFormat.fileZilla, [file]),
        throwsA(
          isA<ThirdPartyBookmarkImportException>()
              .having(
                (error) => error.failure,
                'failure',
                ThirdPartyBookmarkImportFailure.tooManyRows,
              )
              .having(
                (error) => error.sourceName,
                'sourceName',
                'too-many.xml',
              ),
        ),
      );
    });

    test('counts nested FileZilla bookmarks against the row bound', () {
      const bookmark = '<Bookmark><Name>nested</Name></Bookmark>';
      final oversizedFolder = 'x' * 8192;
      final file = _textFile(
        'too-many-bookmarks.xml',
        '<FileZilla3><Servers><Folder>$oversizedFolder<Server>'
            '<Host>files.example.com</Host><Protocol>1</Protocol>'
            '${List.filled(thirdPartyBookmarkImportMaxRows, bookmark).join()}'
            '</Server></Folder></Servers></FileZilla3>',
      );

      expect(
        () => _load(ThirdPartyBookmarkFormat.fileZilla, [file]),
        throwsA(
          isA<ThirdPartyBookmarkImportException>()
              .having(
                (error) => error.failure,
                'failure',
                ThirdPartyBookmarkImportFailure.tooManyRows,
              )
              .having(
                (error) => error.sourceName,
                'sourceName',
                'too-many-bookmarks.xml',
              ),
        ),
      );
    });

    test('budgets defaults before amplified duplicate rows', () {
      const jsonListSeparatorBytes = 1;
      const projectionDeviceId = '00000000-0000-4000-8000-000000000000';
      final keyPath = '/${'k' * 4095}';
      const duplicate = '<Bookmark><Name>copy</Name></Bookmark>';
      const unique = '''
<Bookmark><Name>unique</Name><RemoteDir>/unique</RemoteDir></Bookmark>
''';
      final file = _textFile(
        'amplified.xml',
        '<FileZilla3><Servers><Server>'
            '<Host>files.example.com</Host><Protocol>1</Protocol>'
            '<User>deploy</User><Logontype>5</Logontype>'
            '<Keyfile>$keyPath</Keyfile>'
            '${List.filled(thirdPartyBookmarkImportMaxRows - 2, duplicate).join()}'
            '$unique'
            '</Server></Servers></FileZilla3>',
      );

      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [file]);

      expect(preview.rows, hasLength(thirdPartyBookmarkImportMaxRows));
      expect(preview.rows[1].matchesEarlierImportRow, isTrue);
      expect(preview.rows[1].importable, isTrue);
      expect(preview.rows[1].importByDefault, isFalse);
      final overBudgetDuplicate = preview.rows[preview.rows.length - 2];
      expect(overBudgetDuplicate.matchesEarlierImportRow, isTrue);
      expect(
        overBudgetDuplicate.issues,
        contains(ThirdPartyBookmarkImportIssue.persistedOutputLimitExceeded),
      );
      expect(overBudgetDuplicate.importable, isFalse);

      final uniqueRow = preview.rows.last;
      expect(uniqueRow.remotePath, '/unique');
      expect(uniqueRow.matchesEarlierImportRow, isFalse);
      expect(uniqueRow.importable, isTrue);
      expect(uniqueRow.importByDefault, isTrue);

      final projectionTime = DateTime.utc(9999, 12, 31, 23, 59, 59, 999, 999);
      final envelopeBytes = utf8
          .encode(jsonEncode({'syncTuples': const <String, Object?>{}}))
          .length;
      final projectedBytes = preview.rows
          .where((row) => row.importable)
          .map((row) {
            final bookmarkBytes = utf8
                .encode(
                  jsonEncode(row.toBookmark(now: projectionTime).toJson()),
                )
                .length;
            final tupleBytes = utf8
                .encode(
                  jsonEncode({
                    row.id: {
                      'updatedAt': projectionTime.millisecondsSinceEpoch,
                      'deviceId': projectionDeviceId,
                    },
                  }),
                )
                .length;
            return bookmarkBytes + jsonListSeparatorBytes + tupleBytes;
          })
          .fold(envelopeBytes, (total, bytes) => total + bytes);
      expect(
        projectedBytes,
        lessThanOrEqualTo(thirdPartyBookmarkImportMaxProjectedPersistedBytes),
      );
    });

    test('promotes a fitting duplicate after rejecting its representative', () {
      const projectedBudgetHeadroomBytes = 4096;
      final fillerIdLength =
          (thirdPartyBookmarkImportMaxProjectedPersistedBytes -
              projectedBudgetHeadroomBytes) ~/
          3;
      final ids = <String>[
        'f' * fillerIdLength,
        'large-representative',
        'small-replacement',
      ];
      var nextId = 0;
      final service = ThirdPartyBookmarkImportService(
        mintId: () => ids[nextId++],
      );
      final keyPath = '/${'k' * 4095}';
      final preview = service.loadPreview(
        format: ThirdPartyBookmarkFormat.cyberduck,
        files: [
          _textFile('filler.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>filler.example.com</string></dict></plist>
'''),
          _textFile('large.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>files.example.com</string>
<key>Username</key><string>deploy</string>
<key>Private Key File</key><string>$keyPath</string></dict></plist>
'''),
          _textFile('small.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>FILES.EXAMPLE.COM</string>
<key>Username</key><string>deploy</string></dict></plist>
'''),
        ],
      );

      expect(preview.rows.first.importByDefault, isTrue);
      expect(
        preview.rows[1].issues,
        contains(ThirdPartyBookmarkImportIssue.persistedOutputLimitExceeded),
      );
      expect(preview.rows[1].importable, isFalse);
      expect(preview.rows[2].matchesEarlierImportRow, isFalse);
      expect(preview.rows[2].importable, isTrue);
      expect(preview.rows[2].importByDefault, isTrue);
    });

    test('imported sort keys allow reordering between adjacent rows', () async {
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('ordered.xml', '''
<FileZilla3><Servers><Server>
  <Host>files.example.com</Host><Protocol>1</Protocol><Name>Base</Name>
  <RemoteDir>/base</RemoteDir>
  <Bookmark><Name>One</Name><RemoteDir>/one</RemoteDir></Bookmark>
  <Bookmark><Name>Two</Name><RemoteDir>/two</RemoteDir></Bookmark>
</Server></Servers></FileZilla3>
'''),
      ]);
      final now = DateTime.utc(2026, 10, 1);
      final bookmarks = [
        for (final row in preview.rows) row.toBookmark(now: now),
      ];
      final directory = await Directory.systemTemp.createTemp(
        'poltergeist-import-sort-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}bookmarks.json';
      final store = FileBookmarkStore(path: path, now: () => now);
      await store.upsertAll(bookmarks);

      await store.reorder(
        bookmarks[2].id,
        beforeId: bookmarks[0].id,
        afterId: bookmarks[1].id,
      );

      const maximumExpectedSortKeyLength = 128;
      final sortKeys = bookmarks.map((bookmark) => bookmark.sortKey).toList();
      expect(sortKeys.toSet(), hasLength(3));
      expect(
        sortKeys,
        everyElement(hasLength(lessThan(maximumExpectedSortKeyLength))),
      );
      expect(sortKeys, everyElement(matches(RegExp(r'^[a-z]+$'))));
      for (final sortKey in sortKeys) {
        for (var end = 1; end < sortKey.length; end++) {
          final prefix = sortKey.substring(0, end);
          if (!isValidSortKey(prefix)) continue;

          expect(
            () => sortKeyBetween(prefix, sortKey),
            returnsNormally,
            reason: '$sortKey must leave room after prefix $prefix',
          );
        }
      }
      expect((await store.load()).map((bookmark) => bookmark.id), [
        bookmarks[0].id,
        bookmarks[2].id,
        bookmarks[1].id,
      ]);
    });

    test('imported keys leave room after an ordinary midpoint key', () async {
      final now = DateTime.utc(2026, 10, 1);
      final midpoint = _bookmark(
        'Midpoint',
        host: 'midpoint.example.com',
        sortKey: 'm',
      );
      final mover = _bookmark('Mover', host: 'mover.example.com', sortKey: 'q');
      final imported = _load(
        ThirdPartyBookmarkFormat.cyberduck,
        [
          _textFile('imported.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>imported.example.com</string></dict></plist>
'''),
        ],
        existingBookmarks: [midpoint, mover],
      ).rows.single.toBookmark(now: now);
      final directory = await Directory.systemTemp.createTemp(
        'poltergeist-import-midpoint-sort-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}bookmarks.json';
      final store = FileBookmarkStore(path: path, now: () => now);
      await store.upsertAll([midpoint, imported, mover]);

      await store.reorder(
        mover.id,
        beforeId: midpoint.id,
        afterId: imported.id,
      );

      expect((await store.load()).map((bookmark) => bookmark.id), [
        midpoint.id,
        mover.id,
        imported.id,
      ]);
    });

    test('increments the suffix when an imported sort key collides', () {
      const importedId = 'collision-import';
      final now = DateTime.utc(2026, 10, 1);
      final files = [
        _textFile('collision.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>imported.example.com</string></dict></plist>
'''),
      ];
      final service = ThirdPartyBookmarkImportService(mintId: () => importedId);
      final collidingSortKey = service
          .loadPreview(format: ThirdPartyBookmarkFormat.cyberduck, files: files)
          .rows
          .single
          .toBookmark(now: now)
          .sortKey;
      final existing = _bookmark(
        'Existing',
        host: 'existing.example.com',
        sortKey: collidingSortKey,
      );

      final imported = service
          .loadPreview(
            format: ThirdPartyBookmarkFormat.cyberduck,
            files: files,
            existingBookmarks: [existing],
          )
          .rows
          .single
          .toBookmark(now: now);

      expect(imported.sortKey, isNot(collidingSortKey));
      expect(imported.sortKey.compareTo(collidingSortKey), greaterThan(0));
    });

    test(
      'later imports avoid persisted keys from a one-shot iterable',
      () async {
        final now = DateTime.utc(2026, 10, 1);
        final legacy = _bookmark(
          'Legacy',
          host: 'legacy.example.com',
          sortKey: 'maaa',
        );
        final firstPreview =
            ThirdPartyBookmarkImportService(
              mintId: () => 'first-import',
            ).loadPreview(
              format: ThirdPartyBookmarkFormat.cyberduck,
              files: [
                _textFile('first.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>first.example.com</string></dict></plist>
'''),
              ],
              existingBookmarks: [legacy],
            );
        final first = firstPreview.rows.single.toBookmark(now: now);
        final directory = await Directory.systemTemp.createTemp(
          'poltergeist-import-existing-sort-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}${Platform.pathSeparator}bookmarks.json';
        final store = FileBookmarkStore(path: path, now: () => now);
        await store.upsertAll([legacy, first]);

        final persisted = await store.load();
        var iterations = 0;
        Iterable<Bookmark> existingOnce() sync* {
          iterations++;
          if (iterations > 1) throw StateError('iterated more than once');
          yield* persisted;
        }

        final secondPreview =
            ThirdPartyBookmarkImportService(
              mintId: () => 'second-import',
            ).loadPreview(
              format: ThirdPartyBookmarkFormat.cyberduck,
              files: [
                _textFile('second.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>second.example.com</string></dict></plist>
'''),
              ],
              existingBookmarks: existingOnce(),
            );
        final second = secondPreview.rows.single.toBookmark(now: now);
        await store.upsertAll([second]);

        expect(iterations, 1);
        expect({legacy.sortKey, first.sortKey, second.sortKey}, hasLength(3));
        await store.reorder(legacy.id, beforeId: first.id, afterId: second.id);
        expect((await store.load()).map((bookmark) => bookmark.id), [
          first.id,
          legacy.id,
          second.id,
        ]);
      },
    );

    test('stale previews mint distinct keys that remain reorderable', () async {
      ThirdPartyBookmarkImportPreview preview(String idPrefix) {
        var nextId = 0;

        return ThirdPartyBookmarkImportService(
          mintId: () => '$idPrefix-${nextId++}',
        ).loadPreview(
          format: ThirdPartyBookmarkFormat.cyberduck,
          files: [
            _textFile('$idPrefix-one.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>$idPrefix-one.example.com</string></dict></plist>
'''),
            _textFile('$idPrefix-two.duck', '''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>$idPrefix-two.example.com</string></dict></plist>
'''),
          ],
        );
      }

      final left = preview('left');
      final right = preview('right');
      final now = DateTime.utc(2026, 10, 1);
      final bookmarks = [
        for (final row in [...left.rows, ...right.rows])
          row.toBookmark(now: now),
      ];
      final directory = await Directory.systemTemp.createTemp(
        'poltergeist-import-stale-sort-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}bookmarks.json';
      final store = FileBookmarkStore(path: path, now: () => now);
      await store.upsertAll(left.rows.map((row) => row.toBookmark(now: now)));
      await store.upsertAll(right.rows.map((row) => row.toBookmark(now: now)));

      final persisted = await store.load();
      expect(
        persisted.map((bookmark) => bookmark.sortKey).toSet(),
        hasLength(bookmarks.length),
      );
      await store.reorder(
        persisted.last.id,
        beforeId: persisted[0].id,
        afterId: persisted[1].id,
      );
      expect(await store.load(), hasLength(bookmarks.length));
    });

    test('bounds oversized row fields and disables the row', () {
      const oversizedFieldLength = 8192;
      const maximumExpectedOutputLength = 4096;
      final oversized = 'x' * oversizedFieldLength;
      final preview = _load(ThirdPartyBookmarkFormat.fileZilla, [
        _textFile('$oversized.xml', '''
<FileZilla3><Servers><Folder>$oversized
  <Server><Host>$oversized</Host><Protocol>1</Protocol>
    <User>$oversized</User><Logontype>5</Logontype>
    <Keyfile>/$oversized</Keyfile><Name>$oversized</Name>
    <RemoteDir>/$oversized</RemoteDir>
  </Server>
</Folder></Servers></FileZilla3>
'''),
      ]);

      final row = preview.rows.single;
      expect([
        row.label.length,
        row.host.length,
        row.username.length,
        row.identityFilePath!.length,
        row.remotePath.length,
        row.sourceName.length,
      ], everyElement(lessThanOrEqualTo(maximumExpectedOutputLength)));
      expect(row.remotePath, '/');
      expect(row.issues, contains(ThirdPartyBookmarkImportIssue.fieldTooLong));
      expect(row.importable, isFalse);
    });

    test('rejects excessive FileZilla folder depth', () {
      const excessiveDepth = 65;
      final file = _textFile(
        'deep.xml',
        '<FileZilla3><Servers>'
            '${List.filled(excessiveDepth, '<Folder>nested').join()}'
            '<Server><Host>files.example.com</Host><Protocol>1</Protocol>'
            '</Server>'
            '${List.filled(excessiveDepth, '</Folder>').join()}'
            '</Servers></FileZilla3>',
      );

      expect(
        () => _load(ThirdPartyBookmarkFormat.fileZilla, [file]),
        throwsA(
          isA<ThirdPartyBookmarkImportException>().having(
            (error) => error.failure,
            'failure',
            ThirdPartyBookmarkImportFailure.malformedSource,
          ),
        ),
      );
    });

    test('keeps PuTTY key references visible but disabled', () {
      final preview = _load(ThirdPartyBookmarkFormat.winScp, [
        _textFile('WinSCP.ini', r'''
[Sessions\PuTTY]
HostName=files.example.com
PublicKeyFile=C:%5Ckeys%5Cid_ed25519.PPK
FSProtocol=1

[Sessions\Public key]
HostName=public.example.com
PublicKeyFile=C:%5Ckeys%5Cid_ed25519.pub
FSProtocol=1
'''),
      ]);

      expect(preview.rows.map((row) => row.identityFilePath), [
        r'C:\keys\id_ed25519.PPK',
        r'C:\keys\id_ed25519.pub',
      ]);
      for (final row in preview.rows) {
        expect(
          row.issues,
          contains(ThirdPartyBookmarkImportIssue.unsupportedKeyFormat),
        );
        expect(row.importable, isFalse);
        expect(() => row.toBookmark(now: DateTime.utc(2026)), throwsStateError);
      }
    });

    test('disables hosts containing whitespace or controls', () {
      final preview = _load(ThirdPartyBookmarkFormat.winScp, [
        _textFile('WinSCP.ini', '''
[Sessions\\Whitespace]
HostName=bad host.example.com
FSProtocol=1

[Sessions\\Control]
HostName=bad\u0000host.example.com
FSProtocol=1

[Sessions\\Unicode whitespace]
HostName=bad\u2003host.example.com
FSProtocol=1
'''),
      ]);

      expect(preview.rows, hasLength(3));
      for (final row in preview.rows) {
        expect(row.issues, contains(ThirdPartyBookmarkImportIssue.missingHost));
        expect(row.importable, isFalse);
      }
    });

    test('rejects unpaired UTF-16 surrogates', () {
      final file = ThirdPartyBookmarkImportFile('surrogate.ini', const [
        0xFF,
        0xFE,
        0x00,
        0xD8,
      ]);

      expect(
        () => _load(ThirdPartyBookmarkFormat.winScp, [file]),
        throwsA(
          isA<ThirdPartyBookmarkImportException>().having(
            (error) => error.failure,
            'failure',
            ThirdPartyBookmarkImportFailure.invalidEncoding,
          ),
        ),
      );
    });
  });
}
