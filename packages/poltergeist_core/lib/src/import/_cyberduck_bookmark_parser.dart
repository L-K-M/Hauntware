part of 'third_party_bookmark_import.dart';

const String _cyberduckRoot = 'plist';
const String _cyberduckSftpProtocol = 'sftp';
const String _cyberduckPrivateKey = 'Private Key File';
const String _cyberduckPrivateKeyDictionary = 'Private Key File Dictionary';

List<_ThirdPartyBookmarkDraft> _parseCyberduck(
  ThirdPartyBookmarkImportFile file,
  int rowLimit,
) {
  final document = _parseXml(file);
  final root = document.rootElement;
  if (root.name.local != _cyberduckRoot) {
    throw ThirdPartyBookmarkImportException(
      ThirdPartyBookmarkImportFailure.malformedSource,
      sourceName: file.name,
    );
  }

  XmlElement? dictionary;
  for (final child in root.childElements) {
    if (child.name.local != 'dict') continue;

    dictionary = child;
    break;
  }
  if (dictionary == null) {
    throw ThirdPartyBookmarkImportException(
      ThirdPartyBookmarkImportFailure.malformedSource,
      sourceName: file.name,
    );
  }

  final values = _cyberduckDictionary(dictionary);
  final protocolValue = _cyberduckValue(values['Protocol']) ?? '';
  final protocolToken = protocolValue.trim();
  final normalizedProtocol = protocolToken.toLowerCase();
  _requireImportRowCapacity(0, rowLimit, file.name);

  return [
    _draft(
      sourceName: file.name,
      label: _cyberduckValue(values['Nickname']) ?? '',
      host: _cyberduckValue(values['Hostname']) ?? '',
      rawPort: _cyberduckValue(values['Port']),
      username: _cyberduckValue(values['Username']) ?? '',
      protocol: normalizedProtocol == _cyberduckSftpProtocol
          ? 'SFTP'
          : protocolToken,
      protocolVerdict: protocolToken.isEmpty
          ? ThirdPartyBookmarkProtocolVerdict.unknown
          : ThirdPartyBookmarkProtocolVerdict.known,
      protocolSupport: normalizedProtocol == _cyberduckSftpProtocol
          ? _ProtocolSupport.supported
          : _ProtocolSupport.unsupported,
      identityFilePath: _cyberduckIdentityFile(values),
      remotePath: _remotePath(_cyberduckValue(values['Path'])),
    ),
  ];
}

Map<String, XmlElement> _cyberduckDictionary(XmlElement dictionary) {
  final values = <String, XmlElement>{};
  String? pendingKey;

  for (final child in dictionary.childElements) {
    if (child.name.local == 'key') {
      pendingKey = child.innerText;
      continue;
    }

    final key = pendingKey;
    if (key == null) continue;
    values[key] = child;
    pendingKey = null;
  }

  return values;
}

String? _cyberduckValue(XmlElement? element) {
  if (element == null) return null;
  if (element.name.local != 'string' && element.name.local != 'integer') {
    return null;
  }

  return element.innerText;
}

String? _cyberduckIdentityFile(Map<String, XmlElement> values) {
  final current = values[_cyberduckPrivateKeyDictionary];
  String? currentPath;
  if (current != null && current.name.local == 'dict') {
    final nested = _cyberduckDictionary(current);
    currentPath = _cyberduckValue(nested['Path']);
    if (currentPath != null && currentPath.trim().isEmpty) currentPath = null;
  }

  return currentPath ?? _cyberduckValue(values[_cyberduckPrivateKey]);
}
