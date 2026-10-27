/// Dropbear compatibility (CN-15, 03 §5.9): which Dropbear release a
/// server's SSH identification line names, and what that release means
/// for the transport ladder.
library;

import 'package:meta/meta.dart';

/// Dropbear's identification line: `SSH-2.0-dropbear_2024.86`, or the
/// `SSH-1.99-` form, with an optional comment after a space.
final RegExp _identification = RegExp(
  r'^SSH-(?:2\.0|1\.99)-dropbear_(\d{4})\.(\d{1,3})(?:[ \r]|$)',
);

/// A Dropbear release by its year and the release within it, such as
/// 2024.86.
@immutable
final class DropbearRelease implements Comparable<DropbearRelease> {
  const DropbearRelease(this.year, this.release);

  /// The first release with server-side Unix stream forwarding
  /// (`direct-streamlocal`), which rank 1 of the ladder needs.
  static const unixForwarding = DropbearRelease(2024, 84);

  /// The last release where forwarded Unix connections appeared as root
  /// to the far side's `SO_PEERCRED` (CVE-2025-14282, r5 §1.1); 2025.89
  /// fixed it.
  static const lastPeerCredentialsExposed = DropbearRelease(2025, 88);

  /// The release [identification] names, or null when the server is not
  /// Dropbear or names no release this reads.
  static DropbearRelease? fromIdentification(String? identification) {
    if (identification == null) return null;

    final match = _identification.firstMatch(identification);
    if (match == null) return null;

    return DropbearRelease(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
    );
  }

  final int year;
  final int release;

  /// Whether the server can forward Unix streams, so rank 1 can reach the
  /// engine socket; older releases go straight to the exec relays.
  bool get forwardsUnixStreams => compareTo(unixForwarding) >= 0;

  /// Whether a forwarded Unix connection appears as root to the socket's
  /// owner (CVE-2025-14282).
  bool get exposesPeerCredentials =>
      forwardsUnixStreams && compareTo(lastPeerCredentialsExposed) <= 0;

  @override
  int compareTo(DropbearRelease other) => year != other.year
      ? year.compareTo(other.year)
      : release.compareTo(other.release);

  @override
  bool operator ==(Object other) =>
      other is DropbearRelease &&
      other.year == year &&
      other.release == release;

  @override
  int get hashCode => Object.hash(year, release);

  /// The release as Dropbear numbers it, `2024.86`.
  @override
  String toString() => '$year.${release.toString().padLeft(2, '0')}';
}
