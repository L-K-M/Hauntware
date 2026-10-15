import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/l10n/app_localizations_en.dart';
import 'package:klabautermann_app/ui/freshness.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

final _now = DateTime.utc(2026, 10, 15, 12);
const _staleAfter = Duration(seconds: 20);
final _l10n = AppLocalizationsEn();

SamplingState _phase(SamplingPhase phase, {Duration ago = Duration.zero}) =>
    SamplingState(serverId: 'srv-1', phase: phase, since: _now.subtract(ago));

/// 03 §9.5 item 4's line, in English, for one set of inputs.
String _line({
  Duration? sampleAge,
  SamplingState? sampling,
  bool watched = true,
}) => freshnessText(
  _l10n,
  freshnessOf(
    now: _now,
    staleAfter: _staleAfter,
    lastSampleAt: sampleAge == null ? null : _now.subtract(sampleAge),
    sampling: sampling,
    watched: watched,
  ),
);

void main() {
  group('freshness (03 §9.5 item 4)', () {
    test('a fresh reading says how old it is, in the largest whole unit', () {
      expect(_line(sampleAge: Duration.zero), 'Updated 0 s ago');
      expect(_line(sampleAge: const Duration(seconds: 4)), 'Updated 4 s ago');
      expect(
        _line(
          sampleAge: const Duration(seconds: 19, milliseconds: 999),
          sampling: _phase(SamplingPhase.sampling),
        ),
        'Updated 19 s ago',
      );
    });

    test('a reading as old as the limit is stale, and says so in words', () {
      final stale = freshnessOf(
        now: _now,
        staleAfter: _staleAfter,
        lastSampleAt: _now.subtract(_staleAfter),
        watched: true,
      );

      expect(stale, isA<FreshnessUpdated>());
      expect(stale.stale, isTrue);
      expect(freshnessText(_l10n, stale), 'Stale: updated 20 s ago');
      expect(
        _line(sampleAge: const Duration(minutes: 3, seconds: 59)),
        'Stale: updated 3 min ago',
      );
      expect(
        _line(sampleAge: const Duration(hours: 2, minutes: 59)),
        'Stale: updated 2 h ago',
      );
      expect(
        _line(sampleAge: const Duration(days: 3, hours: 23)),
        'Stale: updated 3 d ago',
      );
    });

    test('a reading stamped after now reads as just taken', () {
      expect(
        _line(sampleAge: const Duration(seconds: -5)),
        'Updated 0 s ago',
        reason: 'only a clock set back makes the age negative (sampleAge)',
      );
    });

    test('the background pause wins over every age', () {
      final paused = freshnessOf(
        now: _now,
        staleAfter: _staleAfter,
        lastSampleAt: _now,
        sampling: _phase(SamplingPhase.pausedInBackground),
        watched: false,
      );

      expect(paused, isA<FreshnessPaused>());
      expect(paused.stale, isTrue);
      expect(freshnessText(_l10n, paused), 'Paused: app in background');
    });

    test('a server this device does not watch and nothing samples is not '
        'watched, whatever it last read', () {
      expect(
        _line(sampleAge: Duration.zero, watched: false),
        'Not watched on this device',
      );
      expect(
        _line(sampling: _phase(SamplingPhase.unsubscribed), watched: false),
        'Not watched on this device',
      );
    });

    test('an unwatched server a view samples anyway reads its age', () {
      expect(
        _line(
          sampleAge: const Duration(seconds: 2),
          sampling: _phase(SamplingPhase.sampling),
          watched: false,
        ),
        'Updated 2 s ago',
      );
    });

    test('a link down after readings says since when, from the phase', () {
      final down = freshnessOf(
        now: _now,
        staleAfter: _staleAfter,
        lastSampleAt: _now.subtract(const Duration(minutes: 4)),
        sampling: _phase(
          SamplingPhase.waitingForLink,
          ago: const Duration(minutes: 3, seconds: 10),
        ),
        watched: true,
      );

      expect(down, isA<FreshnessDisconnected>());
      expect(down.stale, isTrue);
      expect(freshnessText(_l10n, down), 'Disconnected 3 min ago');
    });

    test('without a reading yet there is no age to give', () {
      expect(_line(), 'No data yet');
      expect(_line(sampling: _phase(SamplingPhase.sampling)), 'No data yet');
      expect(
        _line(sampling: _phase(SamplingPhase.waitingForLink)),
        'No data yet',
        reason: 'a link that never came up was not disconnected',
      );
    });

    test('a watched server no surface samples keeps ageing', () {
      expect(
        _line(
          sampleAge: const Duration(minutes: 1),
          sampling: _phase(SamplingPhase.unsubscribed),
        ),
        'Stale: updated 1 min ago',
      );
    });
  });
}
