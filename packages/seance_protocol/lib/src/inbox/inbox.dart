import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto/random.dart';

/// The command inbox: producers (bots, scripts) that may not touch a server
/// hand the user proposed commands through the sync server. See
/// docs/INBOX.md for the design; this file is the part the client and the
/// server must agree on byte for byte.

/// Largest sealed proposal the server accepts.
const int kInboxMaxBlobBytes = 96 * 1024;

/// Largest script a proposal may carry, in UTF-8 bytes.
const int kInboxMaxScriptBytes = 64 * 1024;

const int kInboxMaxTitleChars = 200;
const int kInboxMaxReasonChars = 4000;
const int kInboxMaxNameChars = 100;

/// How long a proposal lives, both the default and the cap on `expires`. The
/// server keeps an item for the same time after receiving it.
const Duration kInboxRetention = Duration(days: 7);

/// How far in the future `created` may lie before a proposal is refused, to
/// absorb clock skew between the producer and this device.
const Duration kInboxClockSkew = Duration(minutes: 10);

const int _kKeyBytes = 32;
const int _kTokenBytes = 32;
const int _kAppIdBytes = 16;
const int _kNonceBytes = 24;
const int _kMacBytes = 16;

const String kInboxPairingPrefix = 'seance-inbox:';
const String _kAadPrefix = 'seance/v1/inbox/';

/// Record-id prefixes for the two synced inbox kinds.
const String kInboxAppIdPrefix = 'inboxapp:';
const String kInboxStatusIdPrefix = 'inboxstatus:';

final RegExp _base64UrlPattern = RegExp(r'^[A-Za-z0-9_-]+$');
final RegExp _proposalIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _unb64(String text) {
  final padded = text.padRight((text.length + 3) ~/ 4 * 4, '=');
  return base64Url.decode(padded);
}

bool _isBase64UrlOfLength(String text, int bytes) =>
    _base64UrlPattern.hasMatch(text) && text.length == (bytes * 4 + 2) ~/ 3;

/// A new app id: 128 random bits, base64url without padding.
String newInboxAppId() => _b64(secureRandomBytes(_kAppIdBytes));

/// A new deposit token: 256 random bits, base64url without padding.
String newInboxToken() => _b64(secureRandomBytes(_kTokenBytes));

/// A new app key for XChaCha20-Poly1305.
Uint8List newInboxKey() => secureRandomBytes(_kKeyBytes);

bool isValidInboxAppId(String id) => _isBase64UrlOfLength(id, _kAppIdBytes);

bool isValidInboxToken(String token) =>
    _isBase64UrlOfLength(token, _kTokenBytes);

bool isValidProposalId(String id) => _proposalIdPattern.hasMatch(id);

/// The wire encryption of a proposal:
/// `nonce(24) || XChaCha20-Poly1305(key, nonce, plaintext, aad) || mac(16)`
/// with `aad = "seance/v1/inbox/" + appId`.
///
/// Authenticated encryption under a key only the producer and the user's
/// vault hold is what makes a proposal trustworthy: the server checks the
/// deposit token, but a breached server can skip that check, so only a key
/// it never sees can prove who wrote a proposal. The associated data binds
/// a blob to its app, so a server holding two apps' items cannot move one.
class InboxCrypto {
  static final Xchacha20 _cipher = Xchacha20.poly1305Aead();

  static List<int> _aad(String appId) => utf8.encode('$_kAadPrefix$appId');

  static Future<Uint8List> seal(
    List<int> key,
    String appId,
    List<int> plaintext,
  ) async {
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      aad: _aad(appId),
    );
    return box.concatenation();
  }

  /// Throws [SecretBoxAuthenticationError] for a wrong key, a wrong app or a
  /// tampered blob, and [FormatException] for one too short to be a box.
  static Future<Uint8List> open(
    List<int> key,
    String appId,
    Uint8List blob,
  ) async {
    if (blob.length < _kNonceBytes + _kMacBytes) {
      throw const FormatException('Inbox item is too short to be sealed');
    }
    final box = SecretBox.fromConcatenation(
      blob,
      nonceLength: _kNonceBytes,
      macLength: _kMacBytes,
    );
    final clear = await _cipher.decrypt(
      box,
      secretKey: SecretKey(key),
      aad: _aad(appId),
    );
    return Uint8List.fromList(clear);
  }
}

/// Everything a producer needs, as one string the user copies once:
/// `seance-inbox:` + base64url(JSON). It is a credential.
class InboxPairing {
  static const int version = 1;

  /// The sync server's base URL.
  final String url;
  final String appId;
  final String token;
  final Uint8List key;

  const InboxPairing({
    required this.url,
    required this.appId,
    required this.token,
    required this.key,
  });

  String get docsUrl => '${url.replaceAll(RegExp(r'/+$'), '')}/llms.txt';

  String encode() => kInboxPairingPrefix +
      _b64(utf8.encode(jsonEncode({
        'v': version,
        'url': url,
        'app': appId,
        'token': token,
        'key': _b64(key),
        'docs': docsUrl,
      })));

  /// Throws [FormatException] for anything that is not a version-1 pairing
  /// string with well-formed fields.
  static InboxPairing decode(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(kInboxPairingPrefix)) {
      throw const FormatException('Not a Séance inbox pairing string');
    }
    final Object? json;
    try {
      json = jsonDecode(
        utf8.decode(_unb64(trimmed.substring(kInboxPairingPrefix.length))),
      );
    } on FormatException {
      throw const FormatException('The pairing string is damaged');
    }
    if (json is! Map || json['v'] != version) {
      throw const FormatException('Unsupported pairing string version');
    }
    final url = json['url'];
    final app = json['app'];
    final token = json['token'];
    final key = json['key'];
    if (url is! String ||
        app is! String ||
        token is! String ||
        key is! String ||
        !isValidInboxAppId(app) ||
        !isValidInboxToken(token) ||
        !_isBase64UrlOfLength(key, _kKeyBytes)) {
      throw const FormatException('The pairing string is damaged');
    }
    return InboxPairing(url: url, appId: app, token: token, key: _unb64(key));
  }
}

/// Why a decrypted proposal was refused.
class InboxProposalException implements Exception {
  final String message;
  const InboxProposalException(this.message);

  @override
  String toString() => 'InboxProposalException: $message';
}

/// A proposed command, version 1, after decryption and validation.
///
/// Decryption proves which app wrote it, not that its content is safe:
/// producers read production error messages, which an attacker can shape.
/// Everything here is validated as untrusted input.
class InboxProposal {
  static const int version = 1;

  final String id;
  final String host;
  final String title;
  final String reason;
  final String script;

  /// Unix seconds, as the producer states them.
  final int created;

  /// Unix seconds, already capped at [created] + [kInboxRetention].
  final int expires;

  const InboxProposal({
    required this.id,
    required this.host,
    required this.title,
    required this.reason,
    required this.script,
    required this.created,
    required this.expires,
  });

  bool isExpiredAt(DateTime now) =>
      now.millisecondsSinceEpoch ~/ 1000 >= expires;

  Map<String, dynamic> toJson() => {
        'v': version,
        'id': id,
        'host': host,
        'title': title,
        if (reason.isNotEmpty) 'reason': reason,
        'script': script,
        'created': created,
        'expires': expires,
      };

  /// Parse and validate decrypted proposal bytes. [now] bounds `created`.
  /// Unknown fields are ignored. Throws [InboxProposalException].
  static InboxProposal parse(List<int> bytes, {required DateTime now}) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const InboxProposalException('Not valid UTF-8 JSON');
    }
    if (json is! Map) {
      throw const InboxProposalException('Not a JSON object');
    }
    return fromJson(json.cast<String, dynamic>(), now: now);
  }

  static InboxProposal fromJson(
    Map<String, dynamic> json, {
    required DateTime now,
  }) {
    if (json['v'] != version) {
      throw const InboxProposalException('Unsupported proposal version');
    }
    final id = json['id'];
    if (id is! String || !isValidProposalId(id)) {
      throw const InboxProposalException(
        'id must be 1 to 64 characters of A-Z, a-z, 0-9, ".", "_" or "-"',
      );
    }
    final host = json['host'];
    if (host is! String || host.trim().isEmpty || _hasLineBreak(host)) {
      throw const InboxProposalException('host must be a non-empty line');
    }
    final title = json['title'];
    if (title is! String ||
        title.trim().isEmpty ||
        title.length > kInboxMaxTitleChars ||
        _hasLineBreak(title)) {
      throw const InboxProposalException(
        'title must be one line of 1 to $kInboxMaxTitleChars characters',
      );
    }
    final reason = json['reason'] ?? '';
    if (reason is! String || reason.length > kInboxMaxReasonChars) {
      throw const InboxProposalException(
        'reason must be at most $kInboxMaxReasonChars characters',
      );
    }
    final script = json['script'];
    if (script is! String ||
        script.trim().isEmpty ||
        utf8.encode(script).length > kInboxMaxScriptBytes) {
      throw const InboxProposalException(
        'script must be 1 byte to 64 KiB of text',
      );
    }
    final created = json['created'];
    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    if (created is! int ||
        created <= 0 ||
        created > nowSeconds + kInboxClockSkew.inSeconds) {
      throw const InboxProposalException(
        'created must be Unix seconds, not in the future',
      );
    }
    final cap = created + kInboxRetention.inSeconds;
    final expires = json['expires'] ?? cap;
    if (expires is! int || expires <= created) {
      throw const InboxProposalException(
        'expires must be Unix seconds after created',
      );
    }
    return InboxProposal(
      id: id,
      host: host.trim(),
      title: title.trim(),
      reason: reason,
      script: script,
      created: created,
      expires: expires < cap ? expires : cap,
    );
  }

  static bool _hasLineBreak(String s) =>
      s.contains('\n') || s.contains('\r') || s.contains(' ');
}

/// A producer the user has connected. Synced as a sealed `inboxapp:` record,
/// which is how the key reaches the user's other devices and never the server.
///
/// Removal is a live record with [removed] set and no key, not a tombstone:
/// tombstones are unsealed (see `SyncCoordinator.applyToStores`), and one
/// honoured here would let a sync server drop apps on every device.
class InboxApp {
  final String id;
  final String name;

  /// Null once [removed].
  final Uint8List? key;

  /// Server ids the app may target. Empty means any server.
  final List<String> allowedServerIds;

  /// Milliseconds since the epoch, like every other record stamp.
  final int createdAt;
  final int updatedAt;
  final bool removed;

  const InboxApp({
    required this.id,
    required this.name,
    required this.key,
    this.allowedServerIds = const [],
    required this.createdAt,
    required this.updatedAt,
    this.removed = false,
  });

  String get recordId => '$kInboxAppIdPrefix$id';

  bool allowsServer(String serverId) =>
      allowedServerIds.isEmpty || allowedServerIds.contains(serverId);

  InboxApp copyWith({
    String? name,
    List<String>? allowedServerIds,
    int? updatedAt,
  }) =>
      InboxApp(
        id: id,
        name: name ?? this.name,
        key: key,
        allowedServerIds: allowedServerIds ?? this.allowedServerIds,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        removed: removed,
      );

  /// The removal marker: same id, no key, no server list.
  InboxApp asRemoved({required int updatedAt}) => InboxApp(
        id: id,
        name: name,
        key: null,
        createdAt: createdAt,
        updatedAt: updatedAt,
        removed: true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (key != null) 'key': _b64(key!),
        if (allowedServerIds.isNotEmpty) 'servers': allowedServerIds,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (removed) 'removed': true,
      };

  /// Throws [FormatException] for a record that is not a usable app: a live
  /// app needs a 32-byte key, a removed one must not carry any.
  factory InboxApp.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final keyText = json['key'];
    final removed = json['removed'] == true;
    if (id is! String || !isValidInboxAppId(id)) {
      throw const FormatException('Inbox app id is malformed');
    }
    if (removed ? keyText != null : keyText is! String) {
      throw const FormatException('Inbox app key is missing or unexpected');
    }
    if (keyText is String && !_isBase64UrlOfLength(keyText, _kKeyBytes)) {
      throw const FormatException('Inbox app key is malformed');
    }
    return InboxApp(
      id: id,
      name: json['name'] as String? ?? '',
      key: keyText is String ? _unb64(keyText) : null,
      allowedServerIds: [
        for (final s in json['servers'] as List? ?? const []) s as String,
      ],
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      removed: removed,
    );
  }

  @override
  String toString() => 'InboxApp(id: $id, name: $name, removed: $removed)';
}

enum InboxStatusState { ran, dismissed }

/// That a proposal was handled, so every device stops announcing it. Holds
/// no script and no output. Synced as a sealed `inboxstatus:` record.
class InboxStatus {
  final String appId;
  final String proposalId;
  final InboxStatusState state;

  /// Milliseconds since the epoch.
  final int updatedAt;

  const InboxStatus({
    required this.appId,
    required this.proposalId,
    required this.state,
    required this.updatedAt,
  });

  static String recordIdFor(String appId, String proposalId) =>
      '$kInboxStatusIdPrefix$appId:$proposalId';

  String get recordId => recordIdFor(appId, proposalId);

  Map<String, dynamic> toJson() => {
        'app': appId,
        'proposal': proposalId,
        'state': state.name,
        'updatedAt': updatedAt,
      };

  factory InboxStatus.fromJson(Map<String, dynamic> json) {
    final app = json['app'];
    final proposal = json['proposal'];
    final state = InboxStatusState.values
        .where((s) => s.name == json['state'])
        .firstOrNull;
    if (app is! String ||
        !isValidInboxAppId(app) ||
        proposal is! String ||
        !isValidProposalId(proposal) ||
        state == null) {
      throw const FormatException('Inbox status is malformed');
    }
    return InboxStatus(
      appId: app,
      proposalId: proposal,
      state: state,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// POST /v1/apps — register an app for the logged-in account.
class CreateInboxAppRequest {
  final String appId;
  final String name;
  final String token;

  const CreateInboxAppRequest({
    required this.appId,
    required this.name,
    required this.token,
  });

  Map<String, dynamic> toJson() => {'app': appId, 'name': name, 'token': token};

  factory CreateInboxAppRequest.fromJson(Map<String, dynamic> json) =>
      CreateInboxAppRequest(
        appId: json['app'] as String,
        name: json['name'] as String? ?? '',
        token: json['token'] as String,
      );
}

/// GET /v1/apps — one registered app as the server knows it.
class InboxAppInfo {
  final String appId;
  final String name;

  /// Milliseconds since the epoch.
  final int created;
  final int pending;

  const InboxAppInfo({
    required this.appId,
    required this.name,
    required this.created,
    required this.pending,
  });

  Map<String, dynamic> toJson() =>
      {'app': appId, 'name': name, 'created': created, 'pending': pending};

  factory InboxAppInfo.fromJson(Map<String, dynamic> json) => InboxAppInfo(
        appId: json['app'] as String,
        name: json['name'] as String? ?? '',
        created: (json['created'] as num?)?.toInt() ?? 0,
        pending: (json['pending'] as num?)?.toInt() ?? 0,
      );
}

/// GET /v1/inbox — one pending sealed item.
class InboxItem {
  final String appId;
  final String itemId;

  /// Server-assigned, strictly increasing per account; the `since` cursor.
  final int received;
  final Uint8List blob;

  const InboxItem({
    required this.appId,
    required this.itemId,
    required this.received,
    required this.blob,
  });

  Map<String, dynamic> toJson() => {
        'app': appId,
        'item': itemId,
        'received': received,
        'blob': base64.encode(blob),
      };

  factory InboxItem.fromJson(Map<String, dynamic> json) => InboxItem(
        appId: json['app'] as String,
        itemId: json['item'] as String,
        received: (json['received'] as num).toInt(),
        blob: base64.decode(json['blob'] as String),
      );
}
