import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Offset, SingleActivator;
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/mac_commands.dart';
import 'package:seance_app/services/mac_context_menu.dart';

/// The Dart half of the native context menus (MainFlutterWindow.swift's
/// ContextMenu): what crosses the channel, and what runs when the native
/// menu answers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(macMenuChannel, null));

  test(
    'rows cross as titles, states and shortcuts; the chosen one runs',
    () async {
      MethodCall? sent;
      messenger.setMockMethodCallHandler(macMenuChannel, (call) async {
        sent = call;
        final items = (call.arguments as Map)['items'] as List;
        return (items.last as Map)['id'];
      });
      final ran = <String>[];
      final shown = await showMacContextMenu([
        MacMenuItem(
          'Copy',
          shortcut: const SingleActivator(LogicalKeyboardKey.keyC, meta: true),
          onSelected: () => ran.add('copy'),
        ),
        const MacMenuItem('Paste'),
        const MacMenuItem.separator(),
        MacMenuItem('Clear', onSelected: () => ran.add('clear')),
      ]);

      expect(shown, isTrue);
      expect(ran, ['clear']);
      expect(sent!.method, 'popUpMenu');
      final items = (sent!.arguments as Map)['items'] as List;
      expect(items[0], {
        'id': '0',
        'title': 'Copy',
        'enabled': true,
        'key': 'c',
        'modifiers': ['command'],
      });
      // A row without a callback shows disabled and has nothing to run.
      expect(items[1], {'title': 'Paste', 'enabled': false});
      expect(items[2], {'separator': true});
    },
  );

  test('an anchor crosses as window points; none means the pointer', () async {
    final sent = <Map>[];
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async {
      sent.add(call.arguments as Map);
      return null;
    });
    await showMacContextMenu(at: const Offset(120, 48.5), [
      const MacMenuItem('Copy'),
    ]);
    await showMacContextMenu([const MacMenuItem('Copy')]);

    expect(sent[0]['x'], 120);
    expect(sent[0]['y'], 48.5);
    expect(sent[1].containsKey('x'), isFalse);
  });

  test('a dismissed menu runs nothing', () async {
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async => null);
    var ran = false;
    final shown = await showMacContextMenu([
      MacMenuItem('Copy', onSelected: () => ran = true),
    ]);
    expect(shown, isTrue);
    expect(ran, isFalse);
  });

  test('without the native side the caller falls back', () async {
    expect(
      await showMacContextMenu([MacMenuItem('Copy', onSelected: () {})]),
      isFalse,
    );
  });
}
