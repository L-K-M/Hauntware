/// The zones the engine evaluates cron next runs in (03 §7.7, D57):
/// the server's zone with the rules `package:timezone`'s database holds
/// for the probe's IANA name, checked against the offset the server
/// reported, else at that fixed offset with the reason; and the zones a
/// `CRON_TZ` names.
///
/// The database is embedded in the engine and loaded on first use. It
/// may disagree with the server's own zone files, which cron reads, so
/// runs within an hour of a transition carry `CronDst.nearTransition`.
/// Its transition tables end at the 32-bit time limit, early in 2038: a
/// run after a zone's last listed transition takes the offset in force
/// after it.
library;

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../engine/protocol.dart';

/// The server zone for cron next runs: [zone] is null when no probe has
/// reported an offset; [zoneName] is set when the runs follow its rules,
/// [fallback] when they follow the probe's fixed offset.
typedef ServerCronZone = ({
  ServerZone? zone,
  String? zoneName,
  CronZoneFallback? fallback,
});

/// The server zone of [profile] at [atUtc], the evaluation instant.
///
/// The rules apply when the database knows the probe's zone name and
/// gives the offset the server reported at the probe's clock reading
/// (at [atUtc] when the probe read no clock, or a reading no DateTime
/// holds). Without a probed offset no zone is known, since nothing
/// confirms the name.
ServerCronZone serverCronZone(HostProfile? profile, DateTime atUtc) {
  final probed = profile?.serverZone;
  if (probed == null) return (zone: null, zoneName: null, fallback: null);

  final name = probed.ianaName;
  final location = name == null ? null : _location(name);
  if (location == null) {
    return (
      zone: probed,
      zoneName: null,
      fallback: name == null
          ? CronZoneFallback.noZoneName
          : CronZoneFallback.unknownZone,
    );
  }
  // The server sends the clock reading; bounding it first keeps the
  // milliseconds from overflowing and DateTime from throwing (6.5).
  final epoch = profile!.epochSeconds;
  final probedAt = epoch == null || epoch.abs() > _maxDateTimeSeconds
      ? atUtc
      : DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
  if (_offsetAt(location, probedAt) != probed.offset) {
    return (
      zone: probed,
      zoneName: null,
      fallback: CronZoneFallback.offsetMismatch,
    );
  }
  return (
    zone: ServerZone(
      offset: probed.offset,
      ianaName: location.name,
      offsetAt: (utc) => _offsetAt(location, utc),
    ),
    zoneName: location.name,
    fallback: null,
  );
}

/// The zone a `CRON_TZ` of [name] names at [atUtc], or null when the
/// database has none of that name (03 §7.7).
ServerZone? cronTzZone(String name, DateTime atUtc) {
  final location = _location(name);
  if (location == null) return null;

  return ServerZone(
    offset: _offsetAt(location, atUtc),
    ianaName: location.name,
    offsetAt: (utc) => _offsetAt(location, utc),
  );
}

/// The largest epoch second a DateTime holds: 100,000,000 days.
const _maxDateTimeSeconds = 8640000000000;

Duration _offsetAt(tz.Location location, DateTime utc) =>
    location.timeZone(utc.millisecondsSinceEpoch).offset;

/// The database's zone named [name], loading the database first; null
/// when it has none.
tz.Location? _location(String name) {
  final database = tz.timeZoneDatabase;
  if (!database.isInitialized) tzdata.initializeTimeZones();
  return database.locations[name];
}
