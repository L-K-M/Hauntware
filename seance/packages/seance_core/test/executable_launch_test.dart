import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  test('the Windows list pins the spec list', () {
    expect(
      windowsExecutableExtensions,
      unorderedEquals(const {
        'bat',
        'cmd',
        'com',
        'scr',
        'ps1',
        'js',
        'jse',
        'vbs',
        'vbe',
        'wsf',
        'wsh',
        'hta',
        'exe',
        'pif',
        'scf',
        'cpl',
        'msp',
        'mst',
        'msi',
        'lnk',
        'url',
        'reg',
        'chm',
        'msc',
        'jar',
        'vb',
        'ws',
        'wsc',
        'sct',
        'application',
        'diagcab',
        'py',
        'pyw',
        'pyz',
        'pyzw',
        'appx',
        'appxbundle',
        'msix',
        'msixbundle',
        'appinstaller',
        'appref-ms',
        'vsto',
        'ppkg',
      }),
    );
  });

  group('isExecutableLaunchName', () {
    bool windows(String name) =>
        isExecutableLaunchName(name, host: LaunchHost.windows);
    bool macos(String name) =>
        isExecutableLaunchName(name, host: LaunchHost.macos);
    bool linux(String name) =>
        isExecutableLaunchName(name, host: LaunchHost.linux);

    test('Windows reads the pinned blocklist, case-insensitively', () {
      for (final extension in windowsExecutableExtensions) {
        expect(windows('payload.$extension'), isTrue, reason: extension);
        expect(
          windows('PAYLOAD.${extension.toUpperCase()}'),
          isTrue,
          reason: extension,
        );
      }
      expect(windows('app.JS'), isTrue);
      expect(windows('notes.txt'), isFalse);
      expect(windows('report.pdf'), isFalse);
      expect(windows('a.tar.gz'), isFalse);
    });

    test('only the LAST extension counts', () {
      expect(windows('invoice.pdf.exe'), isTrue);
      expect(windows('invoice.exe.pdf'), isFalse);
      expect(macos('notes.txt.command'), isTrue);
      expect(linux('readme.md.desktop'), isTrue);
    });

    test('trailing dots and spaces strip the way Win32 resolves names', () {
      // `x.hta.` and `x.exe ` launch as `x.hta` / `x.exe` on Windows;
      // the strip applies on every host, where it only errs toward
      // refusing.
      expect(windows('x.hta.'), isTrue);
      expect(windows('x.exe '), isTrue);
      expect(windows('x.exe. . '), isTrue);
      expect(macos('run.command.'), isTrue);
      expect(windows('.'), isFalse);
      expect(windows('trailing.'), isFalse);
    });

    test('names without an extension are never executable types', () {
      expect(windows('Makefile'), isFalse);
      expect(macos('setup'), isFalse);
      expect(linux('install'), isFalse);
      expect(windows(''), isFalse);
    });

    test('a leading dot still names an extension (Windows semantics)', () {
      // Explorer runs a file named `.js` through Script Host — the
      // preview classifier's dotfile rule must not carry over here.
      expect(windows('.js'), isTrue);
      expect(windows('.bashrc'), isFalse);
    });

    test('classifies the last component of a POSIX or Windows path', () {
      expect(windows('/srv/www/app.js'), isTrue);
      expect(windows(r'C:\Users\me\checkouts\0a1b\app.js'), isTrue);
      expect(windows(r'C:\Users\me\app.js\notes.txt'), isFalse);
      expect(macos('/Users/me/Library/checkouts/0a1b/run.command'), isTrue);
    });

    test('Windows refuses app packages and their referrals', () {
      // App Installer and ClickOnce install and launch these on open.
      for (final name in [
        'Setup.msix',
        'Setup.appx',
        'Suite.msixbundle',
        'Suite.appxbundle',
        'App.appinstaller',
        'Tool.appref-ms',
        'Report.vsto',
        'Kiosk.ppkg',
        // Case and Win32's trailing-dot stripping apply to these too.
        'SETUP.MSIX',
        'Tool.APPREF-MS.',
      ]) {
        expect(windows(name), isTrue, reason: name);
      }
      expect(macos('Setup.msix'), isFalse);
      expect(windows('Old.gadget'), isFalse);
      expect(windows('Orders.accdb'), isFalse);
    });

    test('macOS refuses its own launch types, not Windows ones', () {
      for (final name in [
        'run.command',
        'build.tool',
        'Shell.terminal',
        'Old.term',
        'Evil.app',
        'Flow.workflow',
        'target.fileloc',
        'target.inetloc',
        'target.webloc',
        'tool.jar',
        'Setup.PKG',
        'Bundle.mpkg',
        'Clock.prefPane',
        'Flurry.saver',
        'Photos.slideSaver',
        'Resize.action',
      ]) {
        expect(macos(name), isTrue, reason: name);
      }
      expect(macos('app.js'), isFalse);
      expect(macos('setup.exe'), isFalse);
      expect(macos('script.sh'), isFalse);
    });

    test('Linux refuses launchers that need no execute bit', () {
      for (final name in [
        'app.desktop',
        'Tool.AppImage',
        'tool.jar',
        'agent_1.0_amd64.deb',
        'agent-1.0.x86_64.RPM',
      ]) {
        expect(linux(name), isTrue, reason: name);
      }
      expect(linux('script.sh'), isFalse);
      expect(linux('app.js'), isFalse);
      expect(linux('run.command'), isFalse);
    });
  });
}
