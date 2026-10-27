// CN-15: the Dropbear release a server's SSH identification line names,
// and what it means for the transport ladder.
import 'package:klabautermann_core/src/docker/dropbear.dart';
import 'package:test/test.dart';

void main() {
  DropbearRelease? of(String? line) => DropbearRelease.fromIdentification(line);

  test('reads the release from Dropbear identification lines only', () {
    expect(of('SSH-2.0-dropbear_2024.86'), const DropbearRelease(2024, 86));
    expect(
      of('SSH-2.0-dropbear_2022.83 OpenWrt'),
      const DropbearRelease(2022, 83),
    );
    expect(of('SSH-1.99-dropbear_2025.89'), const DropbearRelease(2025, 89));
    expect(of('SSH-2.0-dropbear_2019.78\r'), const DropbearRelease(2019, 78));
    expect(of('SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13'), isNull);
    expect(of('SSH-2.0-dropbear'), isNull);
    expect(of('SSH-2.0-dropbear_2024.86x'), isNull);
    expect(of(null), isNull);
  });

  test('Unix stream forwarding arrived in 2024.84', () {
    expect(const DropbearRelease(2024, 83).forwardsUnixStreams, isFalse);
    expect(const DropbearRelease(2022, 99).forwardsUnixStreams, isFalse);
    expect(const DropbearRelease(2024, 84).forwardsUnixStreams, isTrue);
    expect(const DropbearRelease(2026, 1).forwardsUnixStreams, isTrue);
  });

  test('CVE-2025-14282 covers 2024.84 to 2025.88', () {
    expect(const DropbearRelease(2024, 83).exposesPeerCredentials, isFalse);
    expect(const DropbearRelease(2024, 84).exposesPeerCredentials, isTrue);
    expect(const DropbearRelease(2025, 88).exposesPeerCredentials, isTrue);
    expect(const DropbearRelease(2025, 89).exposesPeerCredentials, isFalse);
  });

  test('prints as Dropbear numbers it', () {
    expect('${const DropbearRelease(2024, 86)}', '2024.86');
    expect('${const DropbearRelease(2025, 1)}', '2025.01');
  });
}
