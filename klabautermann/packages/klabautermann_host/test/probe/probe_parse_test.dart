// Capability-probe parser tests (03 §6.1): elevation facts including
// `doas -n true`, sudo-rs detection, engine sockets, and the rule that an
// unknown fact stays unknown, never zero.
import 'dart:convert';
import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _ctx = ParseContext.standard;

void main() {
  group('elevation', () {
    test('sudo and a working doas -n true are reported', () {
      final r = parseProbe([
        ProbeSection(
          'elev',
          SectionStatus.ok,
          'sudo_version=Sudo version 1.9.15p5\n'
              'sudo_noninteractive=1\n'
              'doas=present\n'
              'doas_noninteractive=0\n'
              'run0=absent\n'
              'printf=builtin',
        ),
      ], _ctx);
      expect(r.value.sudoKind, SudoKind.sudo);
      expect(r.value.sudoNonInteractive, isFalse);
      expect(r.value.doasPresent, isTrue);
      expect(r.value.doasNonInteractive, isTrue);
      expect(r.value.run0Present, isFalse);
      expect(r.value.printfBuiltin, isTrue);
    });

    test('sudo-rs is told apart from sudo', () {
      final r = parseProbe([
        ProbeSection(
          'elev',
          SectionStatus.ok,
          'sudo_version=sudo-rs 0.2.13\n'
              'sudo_noninteractive=\n'
              'doas=absent\n'
              'doas_noninteractive=\n'
              'run0=present\n'
              'printf=external',
        ),
      ], _ctx);
      expect(r.value.sudoKind, SudoKind.sudoRs);
      expect(r.value.sudoNonInteractive, isNull);
      expect(r.value.doasPresent, isFalse);
      expect(r.value.doasNonInteractive, isNull);
      expect(r.value.run0Present, isTrue);
      expect(r.value.printfBuiltin, isFalse);
    });
  });

  test('an absent probe leaves every fact unknown, not zero', () {
    final r = parseProbe([], _ctx);
    expect(r.value.kernelSys, isNull);
    expect(r.value.uid, isNull);
    expect(r.value.psi, isNull);
    expect(r.value.cUtf8, isNull);
    expect(r.value.lingerEnabled, isNull);
    expect(r.value.engineSockets, isEmpty);
    expect(r.value.areaStatuses, isEmpty);
  });

  test('a non-ok area is recorded and keeps its fields unknown', () {
    final r = parseProbe([
      ProbeSection('kernel', SectionStatus.missing, ''),
      ProbeSection('virt', SectionStatus.denied, 'virt=kvm'),
    ], _ctx);
    expect(r.value.kernelSys, isNull);
    expect(r.value.virtualization, isNull);
    expect(r.value.areaStatuses['kernel'], SectionStatus.missing);
    expect(r.value.areaStatuses['virt'], SectionStatus.denied);
    expect(r.warnings, hasLength(2));
  });

  test('engine sockets keep exists and writable apart', () {
    final r = parseProbe([
      ProbeSection(
        'sockets',
        SectionStatus.ok,
        '/var/run/docker.sock yes yes\n'
            '/run/podman/podman.sock yes no',
      ),
    ], _ctx);
    expect(r.value.engineSockets, hasLength(2));
    expect(r.value.engineSockets[0].exists, isTrue);
    expect(r.value.engineSockets[0].writable, isTrue);
    expect(r.value.engineSockets[1].exists, isTrue);
    expect(r.value.engineSockets[1].writable, isFalse);
  });

  test('kernel features, locale and clock parse', () {
    final r = parseProbe([
      ProbeSection('kfeat', SectionStatus.ok, 'psi=yes\ncgroup_v2=no'),
      ProbeSection('locale', SectionStatus.ok, 'c_utf8=yes'),
      ProbeSection(
        'clock',
        SectionStatus.ok,
        'epoch=1750000000\noffset=+0200\nTimezone=Europe/Berlin',
      ),
    ], _ctx);
    expect(r.value.psi, isTrue);
    expect(r.value.cgroupV2, isFalse);
    expect(r.value.cUtf8, isTrue);
    expect(r.value.epochSeconds, 1750000000);
    expect(r.value.zoneOffset, '+0200');
    expect(r.value.timezone, 'Europe/Berlin');
  });

  group('ProbeSection.fromEvent', () {
    test('strips the probe prefix and the timeout-absent marker', () {
      final s = ProbeSection.fromEvent(
        HwsSection(
          'probe_kernel',
          SectionStatus.ok,
          Uint8List.fromList(
            utf8.encode('hw_timeout=absent\nLinux 6.1 x86_64'),
          ),
        ),
      );
      expect(s, isNotNull);
      expect(s!.name, 'kernel');
      expect(s.payload, 'Linux 6.1 x86_64');
    });

    test('returns null for a non-probe section', () {
      expect(
        ProbeSection.fromEvent(
          HwsSection('overview', SectionStatus.ok, Uint8List(0)),
        ),
        isNull,
      );
    });
  });
}
