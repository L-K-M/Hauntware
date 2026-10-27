import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/main.dart' show AppScope;
import 'package:seance_app/services/mac_commands.dart';
import 'package:seance_app/ui/inspector_page.dart';
import 'package:seance_app/ui/mac_command_host.dart';
import 'package:seance_app/ui/server_list_density.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The Dart half of the native macOS menu bar (MainMenu.swift): what its
/// items do when they call in, and the states Dart tells it. The native
/// half has no test host on Linux; the channel is the contract between
/// them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    await services?.probe.dispose();
    messenger
      ..setMockMethodCallHandler(_pathChannel, null)
      ..setMockMethodCallHandler(macMenuChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    state = null;
    services = null;
    directory = null;
  });

  Future<void> boot(WidgetTester tester) => tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('seance-mac-menu-');
    messenger.setMockMethodCallHandler(
      _pathChannel,
      (call) async => directory!.path,
    );
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services!);
  });

  /// A call as the native menu bar makes it.
  Future<void> fromNative(WidgetTester tester, String method, [Object? args]) =>
      tester.runAsync(
        () => messenger.handlePlatformMessage(
          macMenuChannel.name,
          macMenuChannel.codec.encodeMethodCall(MethodCall(method, args)),
          (_) {},
        ),
      );

  /// Every command state the host has published, merged in order.
  Map<String, Map<Object?, Object?>> published(List<MethodCall> sent) => {
    for (final call in sent)
      if (call.method == 'setCommandStates')
        for (final MapEntry(:key, :value)
            in (call.arguments as Map<Object?, Object?>).entries)
          if (value is Map) key as String: value,
  };

  Future<List<MethodCall>> pumpHost(WidgetTester tester) async {
    final sent = <MethodCall>[];
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async {
      sent.add(call);
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [modalRoutes],
        home: AppScope(
          state: state!,
          child: const MacCommandHost(child: Scaffold()),
        ),
      ),
    );
    await tester.pump();
    return sent;
  }

  testWidgets('View ▸ the density item flips the density, and its title '
      'always names the other choice', (tester) async {
    await boot(tester);
    final sent = await pumpHost(tester);
    // Titled before the menu can be opened: comfortable is the default.
    expect(published(sent)['toggleDensity'], {
      'enabled': true,
      'title': 'Use Compact Sidebar Rows',
    });

    await fromNative(tester, 'run', 'toggleDensity');
    await tester.pump();
    expect(state!.serverListDensity, ServerListDensity.compact);
    expect(
      services!.settings.serverListDensity,
      ServerListDensity.compact,
      reason: 'the menu persists the choice like the switches do',
    );
    expect(
      published(sent)['toggleDensity']?['title'],
      'Use Comfortable Sidebar Rows',
    );

    // A switch elsewhere retitles it too; a notify that changes nothing
    // sends nothing.
    await tester.runAsync(
      () => state!.setServerListDensity(ServerListDensity.comfortable),
    );
    await tester.pump();
    expect(
      published(sent)['toggleDensity']?['title'],
      'Use Compact Sidebar Rows',
    );
    final count = sent.length;
    state!.notifyListeners();
    await tester.pump();
    expect(sent, hasLength(count));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('commands on the window stand down under a dialog', (
    tester,
  ) async {
    await boot(tester);
    final sent = await pumpHost(tester);
    expect(published(sent)['newServer']?['enabled'], true);
    expect(published(sent)['toggleSidebar'], {
      'enabled': true,
      'title': 'Hide Sidebar',
    });
    // Nothing is open: nothing to close, save or disconnect.
    expect(published(sent)['closeTab']?['enabled'], false);
    expect(published(sent)['save']?['enabled'], false);
    expect(published(sent)['disconnect']?['enabled'], false);
    expect(
      sent.last,
      isMethodCall(
        'setWindowTitle',
        arguments: {'title': 'Séance', 'subtitle': ''},
      ),
    );

    final context = tester.element(find.byType(Scaffold));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('Dialog')),
      ),
    );
    await tester.pumpAndSettle();
    expect(published(sent)['newServer']?['enabled'], false);
    expect(published(sent)['toggleSidebar']?['enabled'], false);
    // Settings and Help stay reachable, as under a sheet.
    expect(published(sent)['settings']?['enabled'], true);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(published(sent)['newServer']?['enabled'], true);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('View ▸ Hide Sidebar and the inspector pages persist', (
    tester,
  ) async {
    await boot(tester);
    final sent = await pumpHost(tester);
    expect(published(sent)['showFiles']?['checked'], true);

    await fromNative(tester, 'run', 'toggleSidebar');
    await tester.pump();
    expect(state!.sidebarVisible, isFalse);
    expect(services!.settings.sidebarHidden, isTrue);
    expect(published(sent)['toggleSidebar']?['title'], 'Show Sidebar');

    await fromNative(tester, 'run', 'showGit');
    await tester.pump();
    expect(state!.inspectorPage, InspectorPage.git);
    expect(published(sent)['showGit']?['checked'], true);
    expect(published(sent)['showFiles']?['checked'], false);

    await fromNative(tester, 'run', 'toggleInspector');
    await tester.pump();
    expect(state!.inspectorVisible, isFalse);
    // A hidden inspector checks no page.
    expect(published(sent)['showGit']?['checked'], false);
    await tester.pumpWidget(const SizedBox());
  });
}
