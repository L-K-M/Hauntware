import 'package:flutter/foundation.dart' show immutable;
import 'package:klabautermann_core/klabautermann_core.dart'
    show Sample, SamplingPhase;

import '../controllers/monitoring_controller.dart'
    show SamplingStatus, sampleAge;
import '../l10n/app_localizations.dart';

/// What a freshness line says about one stream of one server (03 §9.5 item
/// 4), from [freshnessOf]; [freshnessText] words it. Rows and cards
/// share it, so "updated 4 s ago" reads the same everywhere.
@immutable
sealed class Freshness {
  const Freshness();

  /// Whether the values this line belongs to are old: 03 §9.5 draws them
  /// grey with an icon beside the words. Only a fresh reading is not.
  bool get stale => true;
}

/// The latest reading is [age] old, and [stale] once that reaches the
/// caller's limit.
final class FreshnessUpdated extends Freshness {
  const FreshnessUpdated(this.age, {required this.stale});

  final Duration age;

  @override
  final bool stale;
}

/// Sampling is paused while the app is in the background, on a phone
/// (D34); it resumes on return.
final class FreshnessPaused extends Freshness {
  const FreshnessPaused();
}

/// This device neither watches the server (FL-21) nor samples it for an
/// open view.
final class FreshnessNotWatched extends Freshness {
  const FreshnessNotWatched();
}

/// The server's link was lost [age] ago while sampling, after readings
/// arrived.
final class FreshnessDisconnected extends Freshness {
  const FreshnessDisconnected(this.age);

  final Duration age;
}

/// Nothing has arrived this engine run, so there is no age to give.
final class FreshnessNoData extends Freshness {
  const FreshnessNoData();
}

/// The freshness of a stream whose latest [Sample.at] is [lastSampleAt]
/// (null without one), as of [now], usually the monitoring clock's value.
///
/// [staleAfter] is the caller's limit for that stream, since cadences
/// differ per stream (03 §6.4). [sampling] is what the engine last said
/// sampling the server is doing; none reads as unsubscribed, the phase
/// every server starts in, since the engine sends one at each change.
/// [watched] says whether the server is in this device's monitor set
/// (FL-21); a server outside it that an open view samples anyway still
/// reads its age. In order: the background pause wins; an unwatched
/// server nothing samples is not watched; a link lost while sampling,
/// after readings, is disconnected since then; otherwise the latest
/// reading gives the age. A link already down when a view or the return
/// from the background subscribed again began its phase only then, so it
/// reads the reading's age.
Freshness freshnessOf({
  required DateTime now,
  required Duration staleAfter,
  DateTime? lastSampleAt,
  required bool watched,
  SamplingStatus? sampling,
}) {
  final phase = sampling?.state.phase;
  if (phase == SamplingPhase.pausedInBackground) return const FreshnessPaused();

  final sampled = phase != null && phase != SamplingPhase.unsubscribed;
  if (!watched && !sampled) return const FreshnessNotWatched();

  final age = sampleAge(lastSampleAt, now);
  if (age == null) return const FreshnessNoData();
  if (phase == SamplingPhase.waitingForLink &&
      sampling!.previous == SamplingPhase.sampling) {
    return FreshnessDisconnected(sampleAge(sampling.state.since, now)!);
  }
  return FreshnessUpdated(age, stale: age >= staleAfter);
}

/// [freshness] in the catalog's words: "Updated 4 s ago", "Stale: updated
/// 3 min ago", "Paused: app in background", "Not watched on this device",
/// "Disconnected 3 min ago" or "No data yet".
String freshnessText(AppLocalizations l10n, Freshness freshness) {
  return switch (freshness) {
    FreshnessUpdated(:final age, stale: false) => l10n.coverageFreshnessUpdated(
      _age(l10n, age),
    ),
    FreshnessUpdated(:final age) => l10n.coverageFreshnessStale(
      _age(l10n, age),
    ),
    FreshnessPaused() => l10n.coverageFreshnessPaused,
    FreshnessNotWatched() => l10n.coverageFreshnessNotWatched,
    FreshnessDisconnected(:final age) => l10n.coverageFreshnessDisconnected(
      _age(l10n, age),
    ),
    FreshnessNoData() => l10n.coverageFreshnessNoData,
  };
}

/// [age] in its largest whole unit, rounded down.
String _age(AppLocalizations l10n, Duration age) {
  if (age < const Duration(minutes: 1)) {
    return l10n.coverageFreshnessSeconds(age.inSeconds);
  }
  if (age < const Duration(hours: 1)) {
    return l10n.coverageFreshnessMinutes(age.inMinutes);
  }
  if (age < const Duration(days: 1)) {
    return l10n.coverageFreshnessHours(age.inHours);
  }
  return l10n.coverageFreshnessDays(age.inDays);
}
