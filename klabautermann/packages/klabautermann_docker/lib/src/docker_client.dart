import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'api_version.dart';
import 'duplex.dart';
import 'errors.dart';
import 'http_client.dart';
import 'http_types.dart';

/// A thin, versioned Engine API client over [DockerHttpClient]
/// (03 §5.5, §5.8). Every path except `/_ping` and `/version` is
/// versioned as `/v<major>.<minor>/...`; `filters` query values are
/// JSON-encoded. Typed endpoint models land with the M3 part 2; this
/// part carries the plumbing every endpoint uses.
final class DockerClient {
  DockerClient(this._http, {required this.apiVersion});

  /// The API version used for versioned paths, usually the negotiated
  /// one from [negotiate].
  final ApiVersion apiVersion;

  /// Feature gates derived from [apiVersion] (03 §5.8); the typed
  /// endpoint helpers read the shape gates from here.
  ApiFeatureGates get gates => ApiFeatureGates(apiVersion);

  final DockerHttpClient _http;

  /// `HEAD /_ping`, falling back to `GET` (03 §5.8): the engine's
  /// `Api-Version` and, on Podman, `Libpod-API-Version`.
  Future<PingInfo> ping({Duration? timeout}) async {
    HttpHeaders headers;
    try {
      final res = await _http.sendBuffered(
        DockerHttpRequest(method: 'HEAD', path: '/_ping', timeout: timeout),
      );
      headers = res.headers;
    } on DockerApiException catch (e) {
      // Daemons without HEAD /_ping answer 404/405/501: retry as GET.
      if (e.statusCode != 404 && e.statusCode != 405 && e.statusCode != 501) {
        rethrow;
      }
      final res = await _http.sendBuffered(
        DockerHttpRequest(method: 'GET', path: '/_ping', timeout: timeout),
      );
      headers = res.headers;
    }
    return parsePingHeaders(headers).value;
  }

  /// `GET /version` (unversioned, 03 §5.8): `ApiVersion`,
  /// `MinAPIVersion` and the engine fields shown in the info panel.
  Future<DockerServerVersion> version({Duration? timeout}) async {
    final res = await _http.sendBuffered(
      DockerHttpRequest(method: 'GET', path: '/version', timeout: timeout),
    );
    return parseServerVersion(_decodeJson(res.body, '/version')).value;
  }

  /// `GET /v<api>/info` as a raw JSON map (typed engine model arrives in
  /// M3 part 2).
  Future<Map<String, Object?>> info({Duration? timeout}) async {
    final res = await _http.sendBuffered(
      DockerHttpRequest(
        method: 'GET',
        path: _versioned('/info'),
        timeout: timeout,
      ),
    );
    final decoded = _decodeJson(res.body, '/info');
    if (decoded is! Map<String, Object?>) {
      throw const DockerProtocolException('/info did not return an object');
    }
    return decoded;
  }

  Object? _decodeJson(Uint8List body, String what) {
    try {
      return jsonDecode(utf8.decode(body));
    } catch (e) {
      throw DockerProtocolException('malformed JSON from $what', cause: e);
    }
  }

  /// `_ping` plus `/version`, then the negotiation of 03 §5.8: throws
  /// [NegotiationRefusedException] when the engine is out of range.
  Future<DockerNegotiation> negotiate({
    ApiVersion clientMax = clientMaxTestedApiVersion,
    ApiVersion floor = clientApiFloor,
    Duration? timeout,
  }) async {
    final ping = await this.ping(timeout: timeout);
    final version = await this.version(timeout: timeout);
    return negotiateApiVersion(
      serverMax: version.apiVersion ?? ping.apiVersion,
      serverMin: version.minApiVersion,
      isPodman: ping.isPodman || version.isPodman,
      clientMax: clientMax,
      floor: floor,
    );
  }

  /// The request plumbing every later endpoint uses (03 §5.5): versioned
  /// paths, `filters` JSON encoding, typed errors. The timeout covers
  /// the whole exchange.
  Future<DockerResponse<Uint8List>> request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? filters,
    Object? json,
    List<int>? body,
    String? contentType,
    Map<String, String>? headers,
    bool versioned = true,
    Duration? timeout,
    DockerCancelToken? cancelToken,
    int maxBytes = defaultMaxBufferedBytes,
  }) => _http.sendBuffered(
    _request(
      method,
      path,
      query: query,
      filters: filters,
      json: json,
      body: body,
      contentType: contentType,
      headers: headers,
      versioned: versioned,
      timeout: timeout,
      cancelToken: cancelToken,
    ),
    maxBytes: maxBytes,
  );

  /// Same plumbing as [request] with the body as a raw chunk stream
  /// (03 §5.5 `bytes`; log and file payloads).
  Future<DockerResponse<Stream<List<int>>>> requestBytes(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? filters,
    Object? json,
    Map<String, String>? headers,
    bool versioned = true,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _http.sendBytes(
    _request(
      method,
      path,
      query: query,
      filters: filters,
      json: json,
      headers: headers,
      versioned: versioned,
      timeout: timeout,
      cancelToken: cancelToken,
    ),
  );

  /// Same plumbing as [request] with the body as JSON-stream lines
  /// (03 §5.5 `lines`; events, stats and logs JSON streams).
  Future<DockerResponse<Stream<String>>> requestLines(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? filters,
    Object? json,
    Map<String, String>? headers,
    bool versioned = true,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _http.sendLines(
    _request(
      method,
      path,
      query: query,
      filters: filters,
      json: json,
      headers: headers,
      versioned: versioned,
      timeout: timeout,
      cancelToken: cancelToken,
    ),
  );

  /// Same plumbing as [request] with the body as concatenated JSON
  /// values (03 §5.5 `jsonValues`; pull progress).
  Future<DockerResponse<Stream<Object?>>> requestJsonValues(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? filters,
    Object? json,
    Map<String, String>? headers,
    bool versioned = true,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _http.sendJsonValues(
    _request(
      method,
      path,
      query: query,
      filters: filters,
      json: json,
      headers: headers,
      versioned: versioned,
      timeout: timeout,
      cancelToken: cancelToken,
    ),
  );

  /// Same plumbing as [request] with the response hijacked on `101` or
  /// `200` (03 §5.5 `hijack`, §5.7 exec start and attach).
  Future<DockerResponse<HijackedDuplex>> requestHijack(
    String method,
    String path, {
    Map<String, String>? query,
    Object? json,
    Map<String, String>? headers,
    bool upgrade = true,
    bool versioned = true,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _http.sendHijack(
    _request(
      method,
      path,
      query: query,
      json: json,
      headers: headers,
      upgrade: upgrade,
      versioned: versioned,
      timeout: timeout,
      cancelToken: cancelToken,
    ),
  );

  /// Closes the underlying connection pool.
  Future<void> close() => _http.close();

  String _versioned(String path) => '/${apiVersion.pathSegment}$path';

  DockerHttpRequest _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? filters,
    Object? json,
    List<int>? body,
    String? contentType,
    Map<String, String>? headers,
    bool upgrade = false,
    bool versioned = true,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) {
    final q = <String, String>{...?query};
    if (filters != null) q['filters'] = jsonEncode(filters);
    return DockerHttpRequest(
      method: method,
      path: versioned ? _versioned(path) : path,
      query: q.isEmpty ? null : q,
      headers: headers,
      json: json,
      body: body,
      contentType: contentType,
      upgrade: upgrade,
      timeout: timeout,
      cancelToken: cancelToken,
    );
  }
}

/// A negotiated [DockerClient] in one step (03 §5.8): runs `_ping` and
/// `/version` through [http], then returns the client bound to the
/// negotiated version together with the negotiation result.
Future<(DockerClient, DockerNegotiation)> negotiateDockerClient(
  DockerHttpClient http, {
  ApiVersion clientMax = clientMaxTestedApiVersion,
  ApiVersion floor = clientApiFloor,
  Duration? timeout,
}) async {
  final probe = DockerClient(http, apiVersion: clientMax);
  final negotiation = await probe.negotiate(
    clientMax: clientMax,
    floor: floor,
    timeout: timeout,
  );
  return (DockerClient(http, apiVersion: negotiation.negotiated), negotiation);
}
