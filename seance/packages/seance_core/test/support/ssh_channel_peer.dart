// Channel-level behaviour for `SshPeerSocket`: the transport fixture
// authenticates the client, then this peer answers channel opens, channel
// requests and channel traffic so tests can drive `SshLink` end to end.
//
// The knobs are deliberately wire-shaped: refusals are reason codes plus
// descriptions, stalls are messages that never get an answer, and silence
// is a global-request handler that stops replying. Everything the client
// sent is recorded on `SshPeerChannel` so tests assert against observed
// wire traffic rather than mocks.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_channel.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_request.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/sftp/sftp_packet.dart';
import 'package:seance_core/seance_core.dart';

import 'ssh_peer.dart';

/// How a refused channel open reads on the wire.
typedef PeerRefusal = ({int reasonCode, String description});

/// RFC 4254 §6.1 reason codes a scripted [PeerRefusal] can use, so tests do
/// not import dartssh2 internals to spell them out.
const peerRefusalAdministrativelyProhibited =
    SSH_Message_Channel_Open_Failure.codeAdministrativelyProhibited;
const peerRefusalConnectFailed =
    SSH_Message_Channel_Open_Failure.codeConnectFailed;

/// A connected [SshLink] with the wire fixture behind it, so a test can set
/// peer knobs before opening a channel and assert against observed traffic
/// afterwards.
typedef TestLink = ({SshLink link, SshChannelPeer peer, SshPeerSocket socket});

/// The config the link tests connect with; the host never resolves because the
/// socket seam is injected.
final testLinkConfig = ServerConfig(
  id: 'link-test',
  label: 'link test',
  host: 'peer.invalid',
  port: 2222,
  username: 'user',
  authMethod: AuthMethod.password,
  createdAt: 0,
  updatedAt: 0,
);

/// Connects an [SshLink] to an in-process peer, accepting its host key.
Future<TestLink> openTestLink({
  Duration timeout = const Duration(seconds: 5),
  Duration idlePingInterval = const Duration(seconds: 15),
  Duration pingTimeout = const Duration(seconds: 30),
  Duration closeTimeout = const Duration(seconds: 5),
  Duration sftpIdleRelease = const Duration(seconds: 60),
  int sessionBudget = 8,
  SshConnectionLog? log,
}) async {
  final socket = SshPeerSocket();
  final peer = SshChannelPeer(socket);
  final link = await SshLink.connect(
    config: testLinkConfig,
    credentials: const SshCredentials.password('test-password'),
    tofu: TofuVerifier(InMemoryHostKeyStore()),
    // The fixture runs a real key exchange, so accepting the key is what
    // lets the handshake finish; host-key policy has its own suite.
    onHostKey: (_) async => true,
    connect: (_, _, _) async => socket,
    timeout: timeout,
    idlePingInterval: idlePingInterval,
    pingTimeout: pingTimeout,
    closeTimeout: closeTimeout,
    sftpIdleRelease: sftpIdleRelease,
    sessionBudget: sessionBudget,
    log: log,
  );
  return (link: link, peer: peer, socket: socket);
}

/// The peer's half of one open channel: observed client traffic plus the
/// send helpers a scripted server uses.
final class SshPeerChannel {
  SshPeerChannel._({
    required this.peer,
    required this.id,
    required this.remoteId,
    required this.type,
    required this.sendWindowRemaining,
  });

  /// The peer that owns this channel.
  final SshChannelPeer peer;

  /// This side's channel number, echoed as `senderChannel` in the open
  /// confirmation.
  final int id;

  /// The client's channel number, used as `recipientChannel` in every
  /// message this side sends.
  final int remoteId;

  /// `session`, `direct-tcpip` or `direct-streamlocal@openssh.com`.
  final String type;

  /// Bytes the client still lets this side send; drains as data goes out
  /// and refills on its window adjustments. Observing it reach zero is how
  /// a test sees backpressure reach the wire.
  int sendWindowRemaining;

  var bytesSent = 0;
  var eofFromClient = false;

  /// A forwarding channel answers the client's EOF with its own EOF and
  /// close, which lets a client close complete. Clear it to keep the read
  /// side open after EOF.
  var closeOnStdinEof = true;
  var closeFromClient = false;
  var eofSent = false;
  var closeSent = false;

  /// CHANNEL_REQUEST observations, in arrival order.
  String? execCommand;
  String? ptyTerm;
  String? subsystem;
  var stdinEof = false;
  final stdinBytes = <int>[];
  final signalsSeen = <String>[];
  final requestsSeen = <String>[];

  /// Bumped once the SFTP version packet has been answered.
  var sftpHandshakeDone = false;

  /// Runs once per channel when the client closes its stdin (CHANNEL_EOF).
  void Function(SshPeerChannel channel)? onStdinEof;

  /// Runs for inbound bytes on a non-session channel; when null the peer
  /// records them in [SshPeerChannel.stdinBytes], as it does for a session.
  void Function(SshPeerChannel channel, Uint8List data)? onData;

  /// Runs for each stdin chunk on a session channel, after the peer
  /// recorded it in [SshPeerChannel.stdinBytes]: a streaming exec reads
  /// its input here.
  void Function(SshPeerChannel channel, Uint8List data)? onStdin;

  var _sftpMode = false;
  final _outbox = Queue<Uint8List>();
  final _sftpBuffer = <int>[];

  /// Queues bytes toward the client, respecting its advertised window:
  /// what the window will not carry waits for WINDOW_ADJUST.
  void sendData(List<int> data) {
    _outbox.add(Uint8List.fromList(data));
    _pump();
  }

  /// Sends one CHANNEL_EXTENDED_DATA (stderr) frame.
  void sendStderr(List<int> data) {
    peer._send(
      SSH_Message_Channel_Extended_Data(
        recipientChannel: remoteId,
        dataTypeCode: SSH_Message_Channel_Extended_Data.dataTypeStderr,
        data: Uint8List.fromList(data),
      ).encode(),
    );
  }

  /// `exit-status` request toward the client.
  void sendExitStatus(int code) {
    peer._send(
      SSH_Message_Channel_Request(
        recipientChannel: remoteId,
        requestType: SSHChannelRequestType.exitStatus,
        wantReply: false,
        exitStatus: code,
      ).encode(),
    );
  }

  /// `exit-signal` request toward the client.
  void sendExitSignal(String signalName) {
    peer._send(
      SSH_Message_Channel_Request(
        recipientChannel: remoteId,
        requestType: SSHChannelRequestType.exitSignal,
        wantReply: false,
        exitSignalName: signalName,
        coreDumped: false,
        errorMessage: '',
        languageTag: '',
      ).encode(),
    );
  }

  /// CHANNEL_EOF toward the client.
  void sendEof() {
    if (eofSent) return;
    eofSent = true;
    peer._send(SSH_Message_Channel_EOF(recipientChannel: remoteId).encode());
  }

  /// CHANNEL_CLOSE toward the client.
  void sendClose() {
    if (closeSent) return;
    closeSent = true;
    peer._send(SSH_Message_Channel_Close(recipientChannel: remoteId).encode());
  }

  void _pump() {
    while (_outbox.isNotEmpty && sendWindowRemaining > 0) {
      final head = _outbox.first;
      var chunk = head.length;
      if (chunk > sendWindowRemaining) chunk = sendWindowRemaining;
      if (chunk > SshChannelPeer.maxPacketSize) {
        chunk = SshChannelPeer.maxPacketSize;
      }
      final piece = Uint8List.sublistView(head, 0, chunk);
      peer._send(
        SSH_Message_Channel_Data(
          recipientChannel: remoteId,
          data: piece,
        ).encode(),
      );
      sendWindowRemaining -= piece.length;
      bytesSent += piece.length;
      if (piece.length == head.length) {
        _outbox.removeFirst();
      } else {
        _outbox
          ..removeFirst()
          ..addFirst(Uint8List.sublistView(head, piece.length));
      }
    }
  }
}

/// A scripted SSH server peer: channel opens, exec/subsystem/pty requests,
/// stdin, EOF, close, duplex data, SFTP INIT/REALPATH and global requests.
final class SshChannelPeer {
  SshChannelPeer(this.socket) {
    socket.onUnknownMessage = _handleChannelMessage;
    socket.onGlobalRequest = _handleGlobalRequest;
  }

  /// The packet bound the peer advertises and respects in both directions,
  /// matching the client's own maximum.
  static const maxPacketSize = 32768;

  /// Default receive window the peer grants the client in confirmations.
  static const defaultWindowSize = 1 << 21;

  final SshPeerSocket socket;

  // ---- knobs ---------------------------------------------------------------

  /// Window this peer grants the client. Lowered by backpressure tests to
  /// watch the grant run out without moving megabytes.
  int windowSize = defaultWindowSize;

  /// Refuse 'session' opens while this many session channels are already
  /// open — the server's `MaxSessions` speaking.
  int? sessionChannelLimit;

  /// Refusal tuple for the session-limit failure; defaults to OpenSSH's
  /// connect-failed "open failed".
  PeerRefusal sessionRefusal = (
    reasonCode: SSH_Message_Channel_Open_Failure.codeConnectFailed,
    description: 'open failed',
  );

  /// Refuse `direct-streamlocal` / `direct-tcpip` opens with this tuple.
  PeerRefusal? streamlocalRefusal;
  PeerRefusal? tcpipRefusal;

  /// Never answer channel opens: opens stall until the caller's bound.
  var ignoreChannelOpens = false;

  /// Answer channel opens only after this delay; a caller with a shorter
  /// open bound abandons the open and the answer arrives late.
  Duration? channelOpenDelay;

  /// Never answer CHANNEL_CLOSE: a peer that hears the close and says
  /// nothing back.
  var ignoreChannelClose = false;

  /// Never answer global requests: the keepalive dead-peer case.
  var silent = false;

  /// Runs after an `exec` request is accepted.
  void Function(SshPeerChannel channel, String command) onExec =
      execEchoAndExit;

  /// Runs once a `direct-streamlocal` or `direct-tcpip` channel is open.
  void Function(SshPeerChannel channel)? onDuplexOpen;

  // ---- observations --------------------------------------------------------

  final channels = <SshPeerChannel>[];

  /// Channel opens received, counted on arrival, before any
  /// [channelOpenDelay]: a test sees that an open is pending.
  var channelOpensSeen = 0;
  var sessionOpenRequests = 0;
  var sessionOpensRefused = 0;
  var globalRequestsSeen = 0;
  var pingRequestsSeen = 0;

  final _channels = <int, SshPeerChannel>{};
  var _nextChannelId = 0;

  /// Session channels the client has opened and not yet fully closed.
  int get openSessionChannels => _channels.values
      .where((c) => c.type == 'session' && !c.closeSent && !c.closeFromClient)
      .length;

  void _send(Uint8List payload) => socket.sendMessage(payload);

  // ---- canned exec behaviours ----------------------------------------------

  /// `ran:<command>` on stdout, exit status 0, EOF, close.
  static void execEchoAndExit(SshPeerChannel channel, String command) {
    channel.sendData(utf8.encode('ran:$command\n'));
    channel.sendExitStatus(0);
    channel.sendEof();
    channel.sendClose();
  }

  /// CHANNEL_SUCCESS for the exec, then nothing: the quiet follower a
  /// budget or ping test keeps open.
  static void execQuietFollower(SshPeerChannel channel, String command) {}

  /// Answers only once stdin EOF arrives: `stdin:<n>` bytes, exit 0.
  static void execAnswerOnStdinEof(SshPeerChannel channel, String command) {
    channel.onStdinEof = (c) {
      c.sendData(utf8.encode('stdin:${c.stdinBytes.length}'));
      c.sendExitStatus(0);
      c.sendEof();
      c.sendClose();
    };
  }

  // ---- message dispatch -----------------------------------------------------

  void _handleChannelMessage(Uint8List payload) {
    switch (payload.first) {
      case SSH_Message_Channel_Open.messageId:
        _onChannelOpen(SSH_Message_Channel_Open.decode(payload));
      case SSH_Message_Channel_Window_Adjust.messageId:
        final message = SSH_Message_Channel_Window_Adjust.decode(payload);
        _channels[message.recipientChannel]!
          ..sendWindowRemaining += message.bytesToAdd
          .._pump();
      case SSH_Message_Channel_Data.messageId:
        final message = SSH_Message_Channel_Data.decode(payload);
        _onChannelData(_channels[message.recipientChannel]!, message.data);
      case SSH_Message_Channel_Extended_Data.messageId:
        break;
      case SSH_Message_Channel_EOF.messageId:
        final message = SSH_Message_Channel_EOF.decode(payload);
        _onChannelEof(_channels[message.recipientChannel]!);
      case SSH_Message_Channel_Close.messageId:
        final message = SSH_Message_Channel_Close.decode(payload);
        _onChannelClose(_channels[message.recipientChannel]!);
      case SSH_Message_Channel_Request.messageId:
        _onChannelRequest(SSH_Message_Channel_Request.decode(payload));
      default:
        throw StateError('The channel peer has no reply for ${payload.first}.');
    }
  }

  void _handleGlobalRequest(SSH_Message_Global_Request request) {
    globalRequestsSeen++;
    if (request.requestName == 'keepalive@openssh.com') pingRequestsSeen++;
    if (silent || !request.wantReply) return;
    _send(
      request.requestName == 'keepalive@openssh.com'
          ? SSH_Message_Request_Success(Uint8List(0)).encode()
          : SSH_Message_Request_Failure().encode(),
    );
  }

  void _onChannelOpen(SSH_Message_Channel_Open message) {
    channelOpensSeen++;
    if (ignoreChannelOpens) return;
    final delay = channelOpenDelay;
    if (delay == null) {
      _answerChannelOpen(message);
    } else {
      Timer(delay, () => _answerChannelOpen(message));
    }
  }

  void _answerChannelOpen(SSH_Message_Channel_Open message) {
    switch (message.channelType) {
      case 'session':
        sessionOpenRequests++;
        final limit = sessionChannelLimit;
        if (limit != null && openSessionChannels >= limit) {
          sessionOpensRefused++;
          _refuseOpen(message.senderChannel, sessionRefusal);
          return;
        }
      case 'direct-streamlocal@openssh.com':
        final refusal = streamlocalRefusal;
        if (refusal != null) {
          _refuseOpen(message.senderChannel, refusal);
          return;
        }
      case 'direct-tcpip':
        final refusal = tcpipRefusal;
        if (refusal != null) {
          _refuseOpen(message.senderChannel, refusal);
          return;
        }
      default:
        _refuseOpen(message.senderChannel, (
          reasonCode: SSH_Message_Channel_Open_Failure.codeUnknownChannelType,
          description: 'unknown channel type',
        ));
        return;
    }

    final channel = SshPeerChannel._(
      peer: this,
      id: _nextChannelId++,
      remoteId: message.senderChannel,
      type: message.channelType,
      sendWindowRemaining: message.initialWindowSize,
    );
    channels.add(channel);
    _channels[channel.id] = channel;
    _send(
      SSH_Message_Channel_Confirmation(
        recipientChannel: message.senderChannel,
        senderChannel: channel.id,
        initialWindowSize: windowSize,
        maximumPacketSize: maxPacketSize,
        data: Uint8List(0),
      ).encode(),
    );
    if (channel.type != 'session') onDuplexOpen?.call(channel);
  }

  void _refuseOpen(int recipientChannel, PeerRefusal refusal) {
    _send(
      SSH_Message_Channel_Open_Failure(
        recipientChannel: recipientChannel,
        reasonCode: refusal.reasonCode,
        description: refusal.description,
      ).encode(),
    );
  }

  void _onChannelRequest(SSH_Message_Channel_Request request) {
    final channel = _channels[request.recipientChannel];
    if (channel == null) return;
    channel.requestsSeen.add(request.requestType);
    void reply(bool ok) {
      if (!request.wantReply) return;
      _send(
        (ok
                ? SSH_Message_Channel_Success(
                    recipientChannel: channel.remoteId,
                  )
                : SSH_Message_Channel_Failure(
                    recipientChannel: channel.remoteId,
                  ))
            .encode(),
      );
    }

    switch (request.requestType) {
      case SSHChannelRequestType.pty:
        channel.ptyTerm = request.termType;
        reply(true);
      case SSHChannelRequestType.exec:
        channel.execCommand = request.command;
        reply(true);
        onExec(channel, request.command ?? '');
      case SSHChannelRequestType.subsystem:
        channel.subsystem = request.subsystemName;
        reply(request.subsystemName == 'sftp');
        if (request.subsystemName == 'sftp') channel._sftpMode = true;
      case SSHChannelRequestType.signal:
        channel.signalsSeen.add(request.signalName ?? '');
      case SSHChannelRequestType.env:
      case SSHChannelRequestType.windowChange:
      case SSHChannelRequestType.shell:
      case SSHChannelRequestType.xon:
        reply(true);
      default:
        reply(false);
    }
  }

  void _onChannelData(SshPeerChannel channel, Uint8List data) {
    if (channel._sftpMode) {
      channel._sftpBuffer.addAll(data);
      _drainSftp(channel);
      return;
    }
    if (channel.type == 'session') {
      channel.stdinBytes.addAll(data);
      channel.onStdin?.call(channel, data);
      return;
    }
    final handler = channel.onData;
    if (handler != null) {
      handler(channel, data);
    } else {
      channel.stdinBytes.addAll(data);
    }
  }

  void _onChannelEof(SshPeerChannel channel) {
    channel.eofFromClient = true;
    channel.stdinEof = true;
    channel.onStdinEof?.call(channel);
    if (channel.type != 'session' && channel.closeOnStdinEof) {
      channel.sendEof();
      channel.sendClose();
    }
  }

  void _onChannelClose(SshPeerChannel channel) {
    channel.closeFromClient = true;
    if (!ignoreChannelClose && !channel.closeSent) channel.sendClose();
  }

  // ---- SFTP ------------------------------------------------------------------

  void _drainSftp(SshPeerChannel channel) {
    final buffer = channel._sftpBuffer;
    while (buffer.length >= 4) {
      final length = ByteData.sublistView(
        Uint8List.fromList(buffer.sublist(0, 4)),
      ).getUint32(0);
      if (buffer.length < 4 + length) return;
      final packet = Uint8List.fromList(buffer.sublist(4, 4 + length));
      buffer.removeRange(0, 4 + length);
      _handleSftpPacket(channel, packet);
    }
  }

  void _handleSftpPacket(SshPeerChannel channel, Uint8List packet) {
    switch (packet.first) {
      case SftpInitPacket.packetType:
        channel.sftpHandshakeDone = true;
        _sendSftp(channel, SftpVersionPacket(3).encode());
      case SftpRealpathPacket.packetType:
        final request = SftpRealpathPacket.decode(packet);
        _sendSftp(
          channel,
          SftpNamePacket(request.requestId, [
            SftpName(
              filename: request.path,
              longname: request.path,
              attr: SftpFileAttrs(),
            ),
          ]).encode(),
        );
      default:
        if (packet.length >= 5) {
          final requestId = ByteData.sublistView(packet, 1).getUint32(0);
          _sendSftp(
            channel,
            SftpStatusPacket(
              requestId: requestId,
              code: SftpStatusCode.failure,
              message: 'unsupported by the test peer',
            ).encode(),
          );
        }
    }
  }

  void _sendSftp(SshPeerChannel channel, Uint8List packet) {
    final writer = BytesBuilder(copy: false);
    writer.add([
      (packet.length >> 24) & 0xff,
      (packet.length >> 16) & 0xff,
      (packet.length >> 8) & 0xff,
      packet.length & 0xff,
    ]);
    writer.add(packet);
    channel.sendData(writer.takeBytes());
  }
}
