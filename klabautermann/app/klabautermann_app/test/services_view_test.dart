import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/log_reads.dart';
import 'package:klabautermann_app/l10n/app_localizations_en.dart';
import 'package:klabautermann_app/ui/services_view.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

SystemdUnit _unit(String name, [String? load, String? active, String? sub]) =>
    SystemdUnit(unit: name, load: load, active: active, sub: sub);

const UnitStates _unknown = (type: null, load: null, active: null, sub: null);

/// SVC-01's states and filters, CN-10's unknowns, and SVC-04's read
/// notices: the Services panel's rules without a widget.
void main() {
  test('keeps the values systemd uses in each column', () {
    expect(
      unitStatesOf(_unit('nginx.service', 'loaded', 'active', 'running')),
      (
        type: UnitType.service,
        load: 'loaded',
        active: UnitActiveState.active,
        sub: 'running',
      ),
    );
    expect(
      unitStatesOf(_unit('a.b.timer', 'not-found', 'failed', 'start-pre')),
      (
        type: UnitType.timer,
        load: 'not-found',
        active: UnitActiveState.failed,
        sub: 'start-pre',
      ),
    );
    expect(unitStatesOf(_unit('x.mount', 'bad-setting')).load, 'bad-setting');
  });

  test('reads a value outside its column as unknown (CN-10)', () {
    expect(unitStatesOf(_unit('cron.service', 'Loaded', 'running', 'dead!')), (
      type: UnitType.service,
      load: null,
      active: null,
      sub: null,
    ));
    expect(unitStatesOf(_unit('cron.service', null, '', '')).sub, isNull);
  });

  test('reads every state of a misread text row as unknown', () {
    // `systemctl --plain` text led by a status bullet, read by position:
    // each column holds its left neighbour's value.
    expect(
      unitStatesOf(_unit('●', 'nginx.service', 'loaded', 'failed')),
      _unknown,
    );
    for (final name in ['service', '.service', 'foo.bar']) {
      expect(unitStatesOf(_unit(name, 'loaded')), _unknown, reason: name);
    }
  });

  test('reads the description of a misread text row as unknown', () {
    SystemdUnit described(String name) => SystemdUnit(
      unit: name,
      load: 'loaded',
      active: 'failed',
      sub: 'failed',
      description: 'failed A web server',
    );

    expect(unitDescriptionOf(described('●')), isNull);
    expect(
      unitDescriptionOf(described('nginx.service')),
      'failed A web server',
    );
  });

  test('filters by type and state, unknown being a value of its own', () {
    final units = [
      _unit('ssh.service', 'loaded', 'active', 'running'),
      _unit('nginx.service', 'loaded', 'failed', 'failed'),
      _unit('ssh.socket', 'loaded', 'active', 'listening'),
      _unit('odd.service', 'loaded', 'sleeping', 'dead'),
      _unit('●', 'x.service', 'loaded', 'failed'),
    ];
    List<String> kept(
      UnitFilter<UnitType> type,
      UnitFilter<UnitActiveState> state,
    ) => [
      for (final unit in filterUnits(units, type: type, state: state))
        unit.unit,
    ];
    const any = (any: true, value: null);
    const service = (any: false, value: UnitType.service);

    expect(kept(service, any), ['ssh.service', 'nginx.service', 'odd.service']);
    expect(kept(any, (any: false, value: UnitActiveState.active)), [
      'ssh.service',
      'ssh.socket',
    ]);
    expect(kept(any, any), hasLength(units.length));
    expect(kept(service, (any: false, value: null)), ['odd.service']);
    expect(kept((any: false, value: null), any), ['●']);
  });

  test('offers every unit, the present values in order, then unknown', () {
    expect(
      filterChoices(
        [UnitType.socket, null, UnitType.service, UnitType.socket],
        UnitType.values,
        (any: true, value: null),
      ),
      [
        (any: true, value: null),
        (any: false, value: UnitType.service),
        (any: false, value: UnitType.socket),
        (any: false, value: null),
      ],
    );
    // The selected value stays a choice when no unit holds it.
    expect(
      filterChoices(
        [UnitActiveState.active],
        UnitActiveState.values,
        (any: false, value: UnitActiveState.failed),
      ),
      [
        (any: true, value: null),
        (any: false, value: UnitActiveState.active),
        (any: false, value: UnitActiveState.failed),
      ],
    );
  });

  group('unitLogsNotice', () {
    final l10n = AppLocalizationsEn();
    late LogReads reads;
    late LogRead read;
    late String streamId;

    setUp(() {
      final sent = <EngineRequest>[];
      reads = LogReads(sent.add);
      read = reads.open(
        LogStreamSpec(
          serverId: 'srv-1',
          source: const JournalLogSource(unit: 'nginx.service'),
          window: kUnitLogWindow,
          follow: false,
        ),
      );
      streamId = (sent.single as OpenLogStream).streamId;
    });

    String? after(LogStreamStatus status) {
      reads.accept(LogStreamState(streamId, status));
      return unitLogsNotice(l10n, read);
    }

    test('says what an unanswered, refused or waiting read does', () {
      expect(unitLogsNotice(l10n, read), l10n.servicesLogsRequested);
      expect(
        after(const LogStreamWaiting(LogStreamWaitReason.link)),
        l10n.servicesLogsWaitingLink,
      );
      expect(
        after(const LogStreamWaiting(LogStreamWaitReason.channel)),
        l10n.servicesLogsWaitingChannel,
      );
      expect(
        after(const LogStreamWaiting(LogStreamWaitReason.background)),
        l10n.servicesLogsWaitingBackground,
      );
      expect(after(const LogStreamRunning()), l10n.servicesLogsReading);
    });

    test('words a refused open', () {
      reads.accept(const RequestRejected('OpenLogStream', 'not yet'));

      expect(unitLogsNotice(l10n, read), l10n.servicesLogsRefused);
    });

    test('says nothing over lines', () {
      reads.accept(
        LogBatch(
          streamId: streamId,
          records: const [JournalRecord(message: 'started')],
        ),
      );

      expect(after(const LogStreamRunning()), isNull);
      expect(
        after(const LogStreamEnded(LogStreamEndReason.windowFilled)),
        isNull,
      );
    });

    for (final (reason, words) in [
      (LogStreamEndReason.oldestReached, l10n.servicesLogsEmpty),
      (LogStreamEndReason.windowFilled, l10n.servicesLogsEmpty),
      (LogStreamEndReason.invalid, l10n.servicesLogsInvalid),
      (LogStreamEndReason.missing, l10n.servicesLogsMissing),
      (LogStreamEndReason.denied, l10n.servicesLogsDenied),
      (LogStreamEndReason.failed, l10n.servicesLogsFailed),
    ]) {
      test('words an end for ${reason.name}', () {
        expect(after(LogStreamEnded(reason)), words);
      });
    }
  });
}
