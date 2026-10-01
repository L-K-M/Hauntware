part of 'third_party_bookmark_import.dart';

const String _winScpSessionPrefix = 'sessions\\';
const String _winScpDefaultSettings = 'Default Settings';
const String _winScpSftpProtocol = '1';
const String _winScpSftpOnlyProtocol = '2';
const Set<String> _winScpImportedKeys = {
  'hostname',
  'portnumber',
  'username',
  'publickeyfile',
  'fsprotocol',
  'remotedirectory',
  'tunnel',
  'proxymethod',
};
const Set<String> _winScpStringKeys = {
  'hostname',
  'username',
  'publickeyfile',
  'remotedirectory',
};

List<_ThirdPartyBookmarkDraft> _parseWinScp(
  ThirdPartyBookmarkImportFile file,
  int rowLimit,
) {
  String unmunge(String value) {
    try {
      return _winScpUnmunge(value);
    } on FormatException {
      throw ThirdPartyBookmarkImportException(
        ThirdPartyBookmarkImportFailure.malformedSource,
        sourceName: file.name,
      );
    }
  }

  final sections = _parseWinScpIni(_decodeText(file));
  final drafts = <_ThirdPartyBookmarkDraft>[];

  for (final section in sections) {
    final normalizedName = section.name.toLowerCase();
    if (!normalizedName.startsWith(_winScpSessionPrefix)) continue;

    final encodedLabel = section.name.substring(_winScpSessionPrefix.length);
    if (encodedLabel.isEmpty) continue;
    final label = unmunge(encodedLabel);
    if (label.toLowerCase() == _winScpDefaultSettings.toLowerCase()) continue;

    final values = <String, String>{};
    for (final entry in section.values.entries) {
      final key = entry.key.trim().toLowerCase();
      if (!_winScpImportedKeys.contains(key)) continue;

      final rawValue = entry.value.trim();
      values[key] = _winScpStringKeys.contains(key)
          ? unmunge(rawValue)
          : rawValue;
    }

    final protocolCode = values['fsprotocol'] ?? _winScpSftpProtocol;
    final protocol = _winScpProtocol(protocolCode);
    final supported =
        protocolCode == _winScpSftpProtocol ||
        protocolCode == _winScpSftpOnlyProtocol;
    final routeNotImported =
        _winScpFlag(values['tunnel']) ||
        _winScpUsesProxy(values['proxymethod']);
    final endpoint = _winScpEndpoint(
      values['hostname'] ?? '',
      values['username'] ?? '',
    );

    _requireImportRowCapacity(drafts.length, rowLimit, file.name);
    drafts.add(
      _draft(
        sourceName: file.name,
        label: label,
        host: endpoint.host,
        rawPort: values['portnumber'],
        username: endpoint.username,
        protocol: protocol.identifier,
        protocolVerdict: protocol.verdict,
        protocolSupport: supported
            ? _ProtocolSupport.supported
            : _ProtocolSupport.unsupported,
        identityFilePath: values['publickeyfile'],
        remotePath: _remotePath(values['remotedirectory']),
        routeSupport: routeNotImported
            ? _RouteSupport.notImported
            : _RouteSupport.direct,
      ),
    );
  }

  return drafts;
}

final class _WinScpIniSection {
  final String name;
  final Map<String, String> values;

  const _WinScpIniSection(this.name, this.values);
}

Iterable<_WinScpIniSection> _parseWinScpIni(String text) sync* {
  String? currentName;
  Map<String, String>? currentValues;

  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) {
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      final name = currentName;
      final values = currentValues;
      if (name != null && values != null) {
        yield _WinScpIniSection(name, values);
      }

      currentName = line.substring(1, line.length - 1).trim();
      currentValues = <String, String>{};
      continue;
    }

    final values = currentValues;
    if (values == null) continue;
    final separator = rawLine.indexOf('=');
    if (separator <= 0) continue;

    final key = rawLine.substring(0, separator).trim();
    if (key.isEmpty) continue;
    values[key] = rawLine.substring(separator + 1);
  }

  final name = currentName;
  final values = currentValues;
  if (name != null && values != null) {
    yield _WinScpIniSection(name, values);
  }
}

/// Reverses WinSCP/PuTTY registry escaping. Unicode values carry a percent-
/// escaped UTF-8 BOM; legacy values are byte strings and remain Latin-1.
String _winScpUnmunge(String input) {
  final bytes = <int>[];
  var hasRawUnicode = false;
  for (var index = 0; index < input.length;) {
    if (input[index] == '%' && index + 2 < input.length) {
      final escaped = int.tryParse(
        input.substring(index + 1, index + 3),
        radix: 16,
      );
      if (escaped != null) {
        bytes.add(escaped);
        index += 3;
        continue;
      }
    }

    final first = input.codeUnitAt(index);
    if (first > 0x7F) hasRawUnicode = true;
    final runeLength =
        first >= 0xD800 &&
            first <= 0xDBFF &&
            index + 1 < input.length &&
            input.codeUnitAt(index + 1) >= 0xDC00 &&
            input.codeUnitAt(index + 1) <= 0xDFFF
        ? 2
        : 1;
    bytes.addAll(utf8.encode(input.substring(index, index + runeLength)));
    index += runeLength;
  }

  if (_listStartsWith(bytes, const [0xEF, 0xBB, 0xBF])) {
    return utf8.decode(bytes.sublist(3), allowMalformed: false);
  }
  if (hasRawUnicode) return utf8.decode(bytes, allowMalformed: true);
  return latin1.decode(bytes, allowInvalid: true);
}

({String host, String username}) _winScpEndpoint(String host, String username) {
  final separator = host.lastIndexOf('@');
  if (separator < 0) return (host: host, username: username);

  return (
    host: host.substring(separator + 1),
    username: host.substring(0, separator),
  );
}

bool _listStartsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;

  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}

bool _winScpFlag(String? value) {
  if (value == null) return false;

  switch (value.trim().toLowerCase()) {
    case '':
    case '0':
    case 'false':
    case 'no':
    case 'off':
      return false;
    default:
      return true;
  }
}

bool _winScpUsesProxy(String? value) {
  if (value == null) return false;
  final normalized = value.trim().toLowerCase();
  return normalized.isNotEmpty && normalized != '0' && normalized != 'none';
}

({String identifier, ThirdPartyBookmarkProtocolVerdict verdict})
_winScpProtocol(String code) {
  switch (code) {
    case '0':
      return (
        identifier: 'SCP',
        verdict: ThirdPartyBookmarkProtocolVerdict.known,
      );
    case _winScpSftpProtocol:
    case _winScpSftpOnlyProtocol:
      return (
        identifier: 'SFTP',
        verdict: ThirdPartyBookmarkProtocolVerdict.known,
      );
    case '5':
      return (
        identifier: 'FTP',
        verdict: ThirdPartyBookmarkProtocolVerdict.known,
      );
    case '6':
      return (
        identifier: 'WebDAV',
        verdict: ThirdPartyBookmarkProtocolVerdict.known,
      );
    case '7':
      return (
        identifier: 'S3',
        verdict: ThirdPartyBookmarkProtocolVerdict.known,
      );
    default:
      return (
        identifier: code,
        verdict: ThirdPartyBookmarkProtocolVerdict.unknown,
      );
  }
}
