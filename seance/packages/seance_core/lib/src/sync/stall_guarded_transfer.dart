import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Upload chunk size. Small enough that a slow link reports progress well
/// inside any sensible idle timeout, large enough to cost nothing on a fast
/// one.
const int _uploadChunkBytes = 16 * 1024;

/// Sends one request whose body may be large in either direction, failing
/// only when the transfer stops making progress.
///
/// A fixed deadline over the whole exchange cannot fit both a fast LAN and a
/// slow mobile link: a full sync page is several MiB, and a retry asks for the
/// same page, so a link too slow for the deadline never syncs. Instead the
/// transfer fails with a [TimeoutException] when no upload chunk is taken, no
/// response headers arrive and no response chunk is received for
/// [idleTimeout], or when the whole exchange exceeds [totalTimeout], which
/// still bounds a server that trickles bytes forever. A failed transfer is
/// aborted so its connection does not linger.
Future<http.Response> sendStallGuarded(
  http.Client client, {
  required String method,
  required Uri url,
  required Map<String, String> headers,
  Uint8List? body,
  required Duration idleTimeout,
  required Duration totalTimeout,
}) async {
  final abort = Completer<void>();
  final failed = Completer<Never>();
  void fail(String message, Duration limit) {
    if (failed.isCompleted) return;
    failed.completeError(TimeoutException(message, limit));
    if (!abort.isCompleted) abort.complete();
  }

  Timer? idle;
  void progressed() {
    idle?.cancel();
    idle = Timer(
      idleTimeout,
      () => fail('$method ${url.path} stalled', idleTimeout),
    );
  }

  final total = Timer(
    totalTimeout,
    () => fail('$method ${url.path} exceeded its total deadline', totalTimeout),
  );
  // Nothing awaits [failed] once the exchange has finished.
  failed.future.ignore();
  progressed();
  StreamSubscription<List<int>>? reading;
  try {
    final request = _ProgressRequest(
      method,
      url,
      body ?? Uint8List(0),
      onProgress: progressed,
      abortTrigger: abort.future,
    )..headers.addAll(headers);
    final sent = client.send(request);
    final http.StreamedResponse response;
    try {
      response = await Future.any([sent, failed.future]);
    } on TimeoutException {
      // The request may still answer later; drain and drop that answer.
      unawaited(
        sent.then<void>(
          (late) => late.stream.listen(null).cancel(),
          onError: (Object _) {},
        ),
      );
      rethrow;
    }
    progressed();

    final bytes = BytesBuilder(copy: false);
    final done = Completer<void>();
    reading = response.stream.listen(
      (chunk) {
        bytes.add(chunk);
        progressed();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!done.isCompleted) done.completeError(error, stackTrace);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    await Future.any([done.future, failed.future]);
    reading = null;
    return http.Response.bytes(
      bytes.takeBytes(),
      response.statusCode,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  } finally {
    idle?.cancel();
    total.cancel();
    // Not awaited: a cancel can wait on the very source that stalled.
    unawaited(reading?.cancel());
  }
}

/// A request that hands its body to the transport in chunks and reports each
/// one the transport takes. Transports read the body under backpressure, so a
/// chunk taken is a chunk on its way out.
class _ProgressRequest extends http.BaseRequest implements http.Abortable {
  _ProgressRequest(
    super.method,
    super.url,
    this._body, {
    required this.onProgress,
    required this.abortTrigger,
  }) {
    contentLength = _body.length;
  }

  final Uint8List _body;
  final void Function() onProgress;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_chunks());
  }

  Stream<List<int>> _chunks() async* {
    for (var offset = 0; offset < _body.length; offset += _uploadChunkBytes) {
      final end = offset + _uploadChunkBytes < _body.length
          ? offset + _uploadChunkBytes
          : _body.length;
      yield Uint8List.sublistView(_body, offset, end);
      onProgress();
    }
  }
}
