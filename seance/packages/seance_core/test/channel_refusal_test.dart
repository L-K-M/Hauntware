// `classifyChannelRefusal`: what one refused channel open teaches the link,
// read from the RFC 4254 §5.1 reason code the server sent.
import 'package:seance_core/src/ssh/channel_budget.dart';
import 'package:test/test.dart';

/// RFC 4254 §5.1 reason codes.
const _administrativelyProhibited = 1;
const _connectFailed = 2;
const _unknownChannelType = 3;
const _resourceShortage = 4;

void main() {
  group('a forwarding refusal', () {
    for (final kind in [
      ChannelOpenKind.directTcpip,
      ChannelOpenKind.directStreamLocal,
    ]) {
      ChannelRefusal classify(int? code) => classifyChannelRefusal(
        kind,
        observedOpens: 0,
        effectiveLimit: 8,
        reasonCode: code,
        description: 'open failed',
      );

      test('on ${kind.name}: administratively prohibited is forwarding '
          'disabled', () {
        expect(
          classify(_administrativelyProhibited),
          ChannelRefusal.forwardDisabled,
        );
      });

      test('on ${kind.name}: an unknown channel type is forwarding '
          'disabled', () {
        expect(classify(_unknownChannelType), ChannelRefusal.forwardDisabled);
      });

      test('on ${kind.name}: connect failed is the target, not the '
          'server', () {
        expect(classify(_connectFailed), ChannelRefusal.connectFailed);
      });

      test('on ${kind.name}: a resource shortage or no code teaches '
          'nothing', () {
        expect(classify(_resourceShortage), ChannelRefusal.other);
        expect(classify(null), ChannelRefusal.other);
      });
    }
  });

  group('a session refusal', () {
    ChannelRefusal classify(int? code, {int observedOpens = 2}) =>
        classifyChannelRefusal(
          .session,
          observedOpens: observedOpens,
          effectiveLimit: 8,
          reasonCode: code,
          description: '',
        );

    test('connect failed below the ceiling is the session limit', () {
      expect(classify(_connectFailed), ChannelRefusal.sessionLimit);
    });

    test('at the ceiling it teaches nothing', () {
      expect(classify(_connectFailed, observedOpens: 8), ChannelRefusal.other);
    });

    test('administratively prohibited without "open failed" is other', () {
      expect(classify(_administrativelyProhibited), ChannelRefusal.other);
    });
  });
}
