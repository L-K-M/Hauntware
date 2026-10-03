part of 'third_party_bookmark_import.dart';

const String _fileZillaRoot = 'FileZilla3';
const String _fileZillaServers = 'Servers';
const String _fileZillaServer = 'Server';
const String _fileZillaFolder = 'Folder';
const String _fileZillaBookmark = 'Bookmark';
const String _fileZillaSftpProtocol = '1';
const String _fileZillaKeyLogonType = '5';
// FileZilla appends this persisted enum; changing an existing value corrupts
// saved sites. Keep unsupported entries recognizable in the preview.
const Map<String, String> _fileZillaProtocolIdentifiers = {
  '0': 'FTP',
  '1': 'SFTP',
  '2': 'HTTP',
  '3': 'FTPS',
  '4': 'FTPES',
  '5': 'HTTPS',
  '6': 'INSECURE_FTP',
  '7': 'S3',
  '8': 'STORJ',
  '9': 'WEBDAV',
  '10': 'AZURE_FILE',
  '11': 'AZURE_BLOB',
  '12': 'SWIFT',
  '13': 'GOOGLE_CLOUD',
  '14': 'GOOGLE_DRIVE',
  '15': 'DROPBOX',
  '16': 'ONEDRIVE',
  '17': 'B2',
  '18': 'BOX',
  '19': 'INSECURE_WEBDAV',
  '20': 'RACKSPACE',
  '21': 'STORJ_GRANT',
  '22': 'S3_SSO',
  '23': 'GOOGLE_CLOUD_SVC_ACC',
  '24': 'CLOUDFLARE_R2',
};
const int _fileZillaDefaultPathType = 0;
const int _fileZillaUnixPathType = 1;
const int _fileZillaMaximumSafePathLength = 32767;
const int _fileZillaMaximumFolderDepth = 64;

List<_ThirdPartyBookmarkDraft> _parseFileZilla(
  ThirdPartyBookmarkImportFile file,
  int rowLimit,
) {
  final document = _parseXml(file);
  final root = document.rootElement;
  if (root.name.local != _fileZillaRoot) {
    throw ThirdPartyBookmarkImportException(
      ThirdPartyBookmarkImportFailure.malformedSource,
      sourceName: file.name,
    );
  }

  XmlElement? servers;
  for (final child in root.childElements) {
    if (child.name.local != _fileZillaServers) continue;

    servers = child;
    break;
  }
  if (servers == null) return const [];

  final drafts = <_ThirdPartyBookmarkDraft>[];
  final lengthUnit = _fileZillaLengthUnit(root.getAttribute('platform'));
  _collectFileZillaEntries(
    servers,
    const _BoundedImportText('', {}),
    file.name,
    lengthUnit,
    drafts,
    rowLimit,
    0,
  );
  return drafts;
}

void _collectFileZillaEntries(
  XmlElement parent,
  _BoundedImportText folders,
  String sourceName,
  _FileZillaLengthUnit lengthUnit,
  List<_ThirdPartyBookmarkDraft> drafts,
  int rowLimit,
  int folderDepth,
) {
  for (final element in parent.childElements) {
    switch (element.name.local) {
      case _fileZillaServer:
        _requireImportRowCapacity(drafts.length, rowLimit, sourceName);
        final label = _fileZillaLabel(element, folders);
        final serverDraft = _fileZillaDraft(
          element,
          label,
          sourceName,
          lengthUnit,
        );
        drafts.add(serverDraft);

        for (final bookmark in element.childElements) {
          if (bookmark.name.local != _fileZillaBookmark) continue;

          _requireImportRowCapacity(drafts.length, rowLimit, sourceName);
          drafts.add(
            _fileZillaBookmarkDraft(serverDraft, label, bookmark, lengthUnit),
          );
        }
      case _fileZillaFolder:
        if (folderDepth >= _fileZillaMaximumFolderDepth) {
          throw ThirdPartyBookmarkImportException(
            ThirdPartyBookmarkImportFailure.malformedSource,
            sourceName: sourceName,
          );
        }

        final folder = element.children
            .whereType<XmlText>()
            .map((node) => node.value)
            .join()
            .trim();
        final nestedFolders = _appendImportLabelSegment(folders, folder);
        _collectFileZillaEntries(
          element,
          nestedFolders,
          sourceName,
          lengthUnit,
          drafts,
          rowLimit,
          folderDepth + 1,
        );
      default:
        break;
    }
  }
}

_ThirdPartyBookmarkDraft _fileZillaDraft(
  XmlElement server,
  _BoundedImportText label,
  String sourceName,
  _FileZillaLengthUnit lengthUnit,
) {
  final host = _fileZillaChildText(server, 'Host') ?? '';
  final protocolCode = _fileZillaChildText(server, 'Protocol') ?? '0';
  final protocol = _fileZillaProtocol(protocolCode);
  final remoteDirectory = _fileZillaRemotePath(
    _fileZillaChildRawText(server, 'RemoteDir'),
    lengthUnit,
  );
  final logonType = _fileZillaChildText(server, 'Logontype') ?? '0';

  return _draft(
    sourceName: sourceName,
    label: label.value,
    host: host,
    rawPort: _fileZillaChildText(server, 'Port'),
    username: _fileZillaChildText(server, 'User') ?? '',
    protocol: protocol.identifier,
    protocolVerdict: protocol.verdict,
    protocolSupport: protocolCode == _fileZillaSftpProtocol
        ? _ProtocolSupport.supported
        : _ProtocolSupport.unsupported,
    identityFilePath: logonType == _fileZillaKeyLogonType
        ? _fileZillaChildRawText(server, 'Keyfile')
        : null,
    remotePath: remoteDirectory,
    sourceIssues: label.issues,
  );
}

_BoundedImportText _fileZillaLabel(
  XmlElement server,
  _BoundedImportText folders,
) {
  final namedSite = _fileZillaChildText(server, 'Name') ?? '';
  final legacySite = server.children
      .whereType<XmlText>()
      .map((node) => node.value)
      .join()
      .trim();
  final host = _fileZillaChildText(server, 'Host') ?? '';
  final siteName = namedSite.isNotEmpty
      ? namedSite
      : legacySite.isNotEmpty
      ? legacySite
      : host;
  return _appendImportLabelSegment(folders, siteName);
}

_ThirdPartyBookmarkDraft _fileZillaBookmarkDraft(
  _ThirdPartyBookmarkDraft server,
  _BoundedImportText serverLabel,
  XmlElement bookmark,
  _FileZillaLengthUnit lengthUnit,
) {
  final bookmarkName = _fileZillaChildText(bookmark, 'Name') ?? '';
  final label = _appendImportLabelSegment(serverLabel, bookmarkName);
  final encodedRemotePath = _fileZillaChildRawText(bookmark, 'RemoteDir');
  final overridesRemotePath =
      encodedRemotePath != null && encodedRemotePath.trim().isNotEmpty;
  final remotePath = overridesRemotePath
      ? _boundImportRemotePath(
          _fileZillaRemotePath(encodedRemotePath, lengthUnit),
        )
      : _BoundedImportRemotePath(server.remotePath, const {});
  final issuesWithoutRemotePath = <ThirdPartyBookmarkImportIssue>{
    ...server.issuesWithoutRemotePath,
    ...label.issues,
  };
  final remotePathIssues = overridesRemotePath
      ? remotePath.issues
      : server.remotePathIssues;
  final issues = <ThirdPartyBookmarkImportIssue>{
    ...issuesWithoutRemotePath,
    ...remotePathIssues,
  };

  return _ThirdPartyBookmarkDraft(
    label: label.value.isEmpty ? server.label : label.value,
    host: server.host,
    port: server.port,
    username: server.username,
    authMethod: server.authMethod,
    identityFilePath: server.identityFilePath,
    remotePath: remotePath.path,
    protocol: server.protocol,
    protocolVerdict: server.protocolVerdict,
    sourceName: server.sourceName,
    issues: Set.unmodifiable(issues),
    issuesWithoutRemotePath: Set.unmodifiable(issuesWithoutRemotePath),
    remotePathIssues: Set.unmodifiable(remotePathIssues),
  );
}

String? _fileZillaChildText(XmlElement parent, String name) {
  for (final child in parent.childElements) {
    if (child.name.local != name) continue;

    return child.innerText.trim();
  }
  return null;
}

String? _fileZillaChildRawText(XmlElement parent, String name) {
  for (final child in parent.childElements) {
    if (child.name.local != name) continue;

    return child.innerText;
  }
  return null;
}

({String identifier, ThirdPartyBookmarkProtocolVerdict verdict})
_fileZillaProtocol(String code) {
  final identifier = _fileZillaProtocolIdentifiers[code];
  if (identifier == null) {
    return (
      identifier: code,
      verdict: ThirdPartyBookmarkProtocolVerdict.unknown,
    );
  }

  return (
    identifier: identifier,
    verdict: ThirdPartyBookmarkProtocolVerdict.known,
  );
}

enum _FileZillaLengthUnit { utf16CodeUnits, unicodeScalars, auto }

_FileZillaLengthUnit _fileZillaLengthUnit(String? platform) {
  switch (platform?.toLowerCase()) {
    case 'windows':
      return _FileZillaLengthUnit.utf16CodeUnits;
    case 'mac':
    case '*nix':
      return _FileZillaLengthUnit.unicodeScalars;
    default:
      return _FileZillaLengthUnit.auto;
  }
}

_RemotePath _fileZillaRemotePath(
  String? encoded,
  _FileZillaLengthUnit lengthUnit,
) {
  if (encoded == null || encoded.trim().isEmpty) {
    return const _RemotePath(_defaultRemotePath, _RemotePathVerdict.valid);
  }
  if (encoded.startsWith('/')) {
    return _remotePath(encoded);
  }

  final decoded = _decodeFileZillaSafePath(encoded, lengthUnit);
  if (decoded == null) {
    return const _RemotePath(_defaultRemotePath, _RemotePathVerdict.invalid);
  }

  return _remotePath(decoded);
}

/// FileZilla's safe path is length-framed, so spaces in prefixes and segments
/// are data rather than delimiters: `1 0 4 home 9 team docs` ->
/// `/home/team docs`.
String? _decodeFileZillaSafePath(
  String encoded,
  _FileZillaLengthUnit lengthUnit,
) {
  switch (lengthUnit) {
    case _FileZillaLengthUnit.utf16CodeUnits:
      return _decodeFileZillaSafePathWithUnit(
        encoded,
        _FileZillaLengthUnit.utf16CodeUnits,
      );
    case _FileZillaLengthUnit.unicodeScalars:
      return _decodeFileZillaSafePathWithUnit(
        encoded,
        _FileZillaLengthUnit.unicodeScalars,
      );
    case _FileZillaLengthUnit.auto:
      final utf16 = _decodeFileZillaSafePathWithUnit(
        encoded,
        _FileZillaLengthUnit.utf16CodeUnits,
      );
      final scalars = _decodeFileZillaSafePathWithUnit(
        encoded,
        _FileZillaLengthUnit.unicodeScalars,
      );
      if (utf16 == null) return scalars;
      if (scalars == null || scalars == utf16) return utf16;

      // Windows stores UTF-16 lengths; other platforms store scalar lengths.
      // Without a platform marker, two valid interpretations are unsafe.
      return null;
  }
}

String? _decodeFileZillaSafePathWithUnit(
  String encoded,
  _FileZillaLengthUnit lengthUnit,
) {
  var cursor = 0;
  final type = _readFileZillaNumber(encoded, cursor);
  if (type == null || type.next >= encoded.length) return null;
  if (type.value != _fileZillaDefaultPathType &&
      type.value != _fileZillaUnixPathType) {
    return null;
  }
  if (encoded[type.next] != ' ') return null;
  cursor = type.next + 1;

  final prefixLength = _readFileZillaNumber(encoded, cursor);
  if (prefixLength == null) return null;
  // SFTP uses Unix paths. Non-empty prefixes belong to other server types
  // (for example a DOS drive) and cannot be preserved as an SFTP path.
  if (prefixLength.value != 0) return null;
  cursor = prefixLength.next;

  final segments = <String>[];
  while (cursor < encoded.length) {
    if (encoded[cursor] != ' ') return null;
    cursor++;

    final segmentLength = _readFileZillaNumber(encoded, cursor);
    if (segmentLength == null || segmentLength.next >= encoded.length) {
      return null;
    }
    if (segmentLength.value == 0 ||
        segmentLength.value > _fileZillaMaximumSafePathLength) {
      return null;
    }
    if (encoded[segmentLength.next] != ' ') return null;
    cursor = segmentLength.next + 1;
    final segmentEnd = _advanceFileZillaText(
      encoded,
      cursor,
      segmentLength.value,
      lengthUnit,
    );
    if (segmentEnd == null) return null;

    segments.add(encoded.substring(cursor, segmentEnd));
    cursor = segmentEnd;
  }

  return '/${segments.join('/')}';
}

int? _advanceFileZillaText(
  String input,
  int start,
  int length,
  _FileZillaLengthUnit lengthUnit,
) {
  if (lengthUnit == _FileZillaLengthUnit.utf16CodeUnits) {
    final end = start + length;
    return end <= input.length ? end : null;
  }

  var cursor = start;
  for (var count = 0; count < length; count++) {
    if (cursor >= input.length) return null;

    final first = input.codeUnitAt(cursor);
    final pairedSurrogate =
        first >= 0xD800 &&
        first <= 0xDBFF &&
        cursor + 1 < input.length &&
        input.codeUnitAt(cursor + 1) >= 0xDC00 &&
        input.codeUnitAt(cursor + 1) <= 0xDFFF;
    cursor += pairedSurrogate ? 2 : 1;
  }
  return cursor;
}

({int value, int next})? _readFileZillaNumber(String input, int start) {
  if (start >= input.length) return null;

  var cursor = start;
  while (cursor < input.length &&
      input.codeUnitAt(cursor) >= 0x30 &&
      input.codeUnitAt(cursor) <= 0x39) {
    cursor++;
  }
  if (cursor == start) return null;

  final value = int.tryParse(input.substring(start, cursor));
  if (value == null) return null;
  return (value: value, next: cursor);
}
