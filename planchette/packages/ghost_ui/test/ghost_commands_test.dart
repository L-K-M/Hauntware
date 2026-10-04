import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

void main() {
  group('formatShortcutActivator', () {
    test('orders modifiers per platform', () {
      const chord = SingleActivator(
        LogicalKeyboardKey.keyP,
        control: true,
        alt: true,
        shift: true,
        meta: true,
      );
      expect(formatShortcutActivator(chord, TargetPlatform.macOS), '⌃⌥⇧⌘P');
      expect(
        formatShortcutActivator(chord, TargetPlatform.linux),
        'Ctrl+Alt+Shift+Meta+P',
      );
      expect(
        formatShortcutActivator(chord, TargetPlatform.windows),
        'Ctrl+Alt+Shift+Meta+P',
      );
    });

    test('spells trigger glyphs per platform', () {
      const chord = SingleActivator(LogicalKeyboardKey.arrowUp, alt: true);
      expect(formatShortcutActivator(chord, TargetPlatform.macOS), '⌥↑');
      expect(formatShortcutActivator(chord, TargetPlatform.linux), 'Alt+Up');
      const tab = SingleActivator(LogicalKeyboardKey.tab, control: true);
      expect(formatShortcutActivator(tab, TargetPlatform.macOS), '⌃⇥');
      expect(formatShortcutActivator(tab, TargetPlatform.windows), 'Ctrl+Tab');
    });

    test('spells only the modifiers the chord holds', () {
      const chord = SingleActivator(
        LogicalKeyboardKey.keyP,
        control: true,
        shift: true,
      );
      expect(
        formatShortcutActivator(chord, TargetPlatform.linux),
        'Ctrl+Shift+P',
      );
      expect(
        formatShortcutActivator(chord, TargetPlatform.windows),
        'Ctrl+Shift+P',
      );
    });

    test('spells a bare key on its own', () {
      const bare = SingleActivator(LogicalKeyboardKey.arrowUp);
      expect(formatShortcutActivator(bare, TargetPlatform.macOS), '↑');
      expect(formatShortcutActivator(bare, TargetPlatform.linux), 'Up');
    });

    test('iOS is a glyph platform like macOS', () {
      const chord = SingleActivator(LogicalKeyboardKey.keyT, meta: true);
      expect(formatShortcutActivator(chord, TargetPlatform.iOS), '⌘T');
      expect(formatShortcutActivator(chord, TargetPlatform.macOS), '⌘T');
    });

    test('has no spelling for non-SingleActivator chords', () {
      expect(
        formatShortcutActivator(
          const CharacterActivator('a'),
          TargetPlatform.macOS,
        ),
        isNull,
      );
    });
  });

  group('dispatchGhostChord', () {
    var ran = 0;
    setUp(() => ran = 0);

    KeyDownEvent down(LogicalKeyboardKey key) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

    GhostChordBinding binding(
      LogicalKeyboardKey key, {
      bool repeats = true,
      bool leftAltOnly = false,
      bool Function(FocusNode?)? mayRunFrom,
    }) => GhostChordBinding(
      activator: SingleActivator(key),
      onInvoke: () => ran++,
      repeats: repeats,
      leftAltOnly: leftAltOnly,
      mayRunFrom: mayRunFrom,
    );

    test('runs a matching binding and reports handled', () {
      final result = dispatchGhostChord([
        binding(LogicalKeyboardKey.keyA),
      ], down(LogicalKeyboardKey.keyA));
      expect(ran, 1);
      expect(result, KeyEventResult.handled);
    });

    test('ignores non-matching and key-up events', () {
      expect(
        dispatchGhostChord([
          binding(LogicalKeyboardKey.keyA),
        ], down(LogicalKeyboardKey.keyB)),
        KeyEventResult.ignored,
      );
      expect(
        dispatchGhostChord(
          [binding(LogicalKeyboardKey.keyA)],
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.ignored,
      );
      expect(ran, 0);
    });

    test('a non-repeating binding swallows a held repeat', () {
      final event = KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      );
      expect(
        dispatchGhostChord([
          binding(LogicalKeyboardKey.keyA, repeats: false),
        ], event),
        KeyEventResult.handled,
      );
      expect(ran, 0);
      expect(
        dispatchGhostChord([binding(LogicalKeyboardKey.keyA)], event),
        KeyEventResult.handled,
      );
      expect(ran, 1);
    });

    test('a refused mayRunFrom is consumed without running', () {
      final result = dispatchGhostChord([
        binding(LogicalKeyboardKey.keyA, mayRunFrom: (_) => false),
      ], down(LogicalKeyboardKey.keyA));
      expect(result, KeyEventResult.handled);
      expect(ran, 0);
    });

    test('the first accepting binding claims the keystroke', () {
      var second = 0;
      final result = dispatchGhostChord([
        binding(LogicalKeyboardKey.keyA),
        GhostChordBinding(
          activator: const SingleActivator(LogicalKeyboardKey.keyA),
          onInvoke: () => second++,
        ),
      ], down(LogicalKeyboardKey.keyA));
      expect(result, KeyEventResult.handled);
      expect(ran, 1);
      expect(second, 0);
    });
  });

  group('GhostChordScope', () {
    Future<void> pumpScope(
      WidgetTester tester,
      List<GhostChordBinding> bindings, {
      bool suspendWhileEditing = true,
      GhostUnmodifiedChordPolicy unmodifiedPolicy =
          GhostUnmodifiedChordPolicy.ignore,
      Set<LogicalKeyboardKey> unmodifiedTriggers = const {},
      Widget? child,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GhostChordScope(
              bindings: bindings,
              suspendWhileEditing: suspendWhileEditing,
              unmodifiedPolicy: unmodifiedPolicy,
              unmodifiedTriggers: unmodifiedTriggers,
              child: child ?? const Focus(autofocus: true, child: SizedBox()),
            ),
          ),
        ),
      );
    }

    testWidgets('dispatches a bound chord', (tester) async {
      var ran = 0;
      await pumpScope(tester, [
        GhostChordBinding(
          activator: const SingleActivator(
            LogicalKeyboardKey.keyK,
            control: true,
          ),
          onInvoke: () => ran++,
        ),
      ]);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      expect(ran, 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });

    testWidgets('ignores unmodified chords under the ignore policy', (
      tester,
    ) async {
      var ran = 0;
      await pumpScope(tester, [
        GhostChordBinding(
          activator: const SingleActivator(LogicalKeyboardKey.f5),
          onInvoke: () => ran++,
        ),
      ]);
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      expect(ran, 0);

      await pumpScope(
        tester,
        [
          GhostChordBinding(
            activator: const SingleActivator(LogicalKeyboardKey.f5),
            onInvoke: () => ran++,
          ),
        ],
        unmodifiedPolicy: GhostUnmodifiedChordPolicy.allowlisted,
        unmodifiedTriggers: {LogicalKeyboardKey.f5},
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      expect(ran, 1);
    });

    testWidgets('stands down while a text field holds focus', (tester) async {
      var ran = 0;
      await pumpScope(tester, [
        GhostChordBinding(
          activator: const SingleActivator(
            LogicalKeyboardKey.keyK,
            control: true,
          ),
          onInvoke: () => ran++,
        ),
      ], child: const TextField(autofocus: true));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      expect(ran, 0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });
  });

  group('ghostNativeShortcut', () {
    test('binds only modified chords', () {
      expect(
        ghostNativeShortcut(const [
          SingleActivator(LogicalKeyboardKey.enter),
          SingleActivator(LogicalKeyboardKey.keyA, meta: true),
        ]),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true),
      );
      expect(
        ghostNativeShortcut(const [
          SingleActivator(LogicalKeyboardKey.f3),
          SingleActivator(LogicalKeyboardKey.tab, shift: true),
        ]),
        isNull,
      );
    });
  });

  group('ghostEditingTextIntent', () {
    test('maps the field-owned macOS chords', () {
      expect(
        ghostEditingTextIntent(
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true),
        ),
        isA<CopySelectionTextIntent>(),
      );
      expect(
        ghostEditingTextIntent(
          const SingleActivator(
            LogicalKeyboardKey.keyZ,
            meta: true,
            shift: true,
          ),
        ),
        isA<RedoTextIntent>(),
      );
      expect(
        ghostEditingTextIntent(
          const SingleActivator(LogicalKeyboardKey.keyC, control: true),
        ),
        isNull,
      );
    });
  });

  GhostMenu menu() => GhostMenu(
    id: 'file',
    title: 'File',
    groups: [
      [
        GhostCommandRow(
          GhostCommandSpec(
            id: 'a.new',
            label: 'New',
            activators: const [
              SingleActivator(LogicalKeyboardKey.keyN, control: true),
            ],
            onSelected: () {},
          ),
        ),
        GhostCommandRow(
          GhostCommandSpec(
            id: 'a.off',
            label: 'Off',
            enabled: false,
            onSelected: () {},
          ),
        ),
      ],
      [
        GhostSubmenuRow(
          title: 'Sort By',
          items: [
            GhostCommandRow(
              GhostCommandSpec(id: 'a.name', label: 'Name', onSelected: () {}),
            ),
          ],
        ),
      ],
      const [GhostProvidedRow(PlatformProvidedMenuItemType.toggleFullScreen)],
      [
        GhostCommandRow(
          GhostCommandSpec(
            id: 'a.toggle',
            label: 'Toggle',
            checked: true,
            onSelected: () {},
          ),
        ),
      ],
    ],
  );

  group('ghostPlatformMenuGroups', () {
    test('serializes groups, submenus, provided rows and checks', () {
      final items = ghostPlatformMenuGroups(menu().groups);
      expect(items, hasLength(4));
      expect(items, everyElement(isA<PlatformMenuItemGroup>()));
      final first = items.first as PlatformMenuItemGroup;
      expect(first.members[0], isA<PlatformMenuItem>());
      final disabled = first.members[1];
      expect(disabled.onSelected, isNull);
      final submenu = (items[1] as PlatformMenuItemGroup).members.single;
      expect(submenu, isA<PlatformMenu>());
      expect((submenu as PlatformMenu).label, 'Sort By');
      expect(
        (items[2] as PlatformMenuItemGroup).members.single,
        isA<PlatformProvidedMenuItem>(),
      );
      final checkedRow =
          (items[3] as PlatformMenuItemGroup).members.single
              as CheckedPlatformMenuItem;
      expect(checkedRow.checked, isTrue);
    });

    test('applies the activate callback with the bound shortcut', () {
      MenuSerializableShortcut? seen;
      final items = ghostPlatformMenuGroups(
        [
          [
            GhostCommandRow(
              GhostCommandSpec(
                label: 'Copy',
                activators: const [
                  SingleActivator(LogicalKeyboardKey.keyC, meta: true),
                ],
              ),
            ),
          ],
        ],
        activate: (spec, shortcut) {
          seen = shortcut;
          return () {};
        },
      );
      final leaf = (items.single as PlatformMenuItemGroup).members.single;
      expect(seen, const SingleActivator(LogicalKeyboardKey.keyC, meta: true));
      expect(leaf.onSelected, isNotNull);
    });
  });

  group('ghostMenuSignature', () {
    test('equal menus produce equal signatures; enablement flips differ', () {
      final a = ghostMenuSignature([menu()]);
      final b = ghostMenuSignature([menu()]);
      expect(listEquals(a, b), isTrue);
      final changed = GhostMenu(
        id: 'file',
        title: 'File',
        groups: [
          [
            GhostCommandRow(
              GhostCommandSpec(id: 'a.new', label: 'New', onSelected: () {}),
            ),
          ],
        ],
      );
      expect(
        listEquals(ghostMenuSignature([menu()]), ghostMenuSignature([changed])),
        isFalse,
      );
    });
  });

  group('CheckedPlatformMenuItem', () {
    test('serializes the checked flag for the channel', () {
      const item = CheckedPlatformMenuItem(label: 'L', checked: true);
      var id = 0;
      final rep = item.toChannelRepresentation(
        DefaultPlatformMenuDelegate(),
        getId: (_) => ++id,
      );
      expect(rep.single['checked'], isTrue);
    });
  });

  group('CheckedPlatformMenuDelegate', () {
    testWidgets('setMenus reports nothing when the checks peer is absent', (
      tester,
    ) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const menu = MethodChannel('flutter/menu');
      const checks = MethodChannel('test/menu_checks');
      messenger.setMockMethodCallHandler(menu, (call) async => null);
      messenger.setMockMethodCallHandler(
        checks,
        (call) async => throw MissingPluginException(),
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(menu, null);
        messenger.setMockMethodCallHandler(checks, null);
      });
      final delegate = CheckedPlatformMenuDelegate(
        channelName: 'test/menu_checks',
      );
      delegate.setMenus([
        PlatformMenu(
          label: 'File',
          menus: [
            PlatformMenuItemGroup(
              members: [
                CheckedPlatformMenuItem(
                  label: 'Check',
                  checked: true,
                  onSelected: () {},
                ),
              ],
            ),
          ],
        ),
      ]);
      await tester.pump();
      // Without the swallow the missing peer surfaces a reported
      // MissingPluginException on every push.
      expect(tester.takeException(), isNull);
    });
  });

  group('GhostShortcutHint', () {
    Future<Text> pumpHint(WidgetTester tester, bool enabled) {
      return tester
          .pumpWidget(
            MaterialApp(
              home: GhostShortcutHint(
                const SingleActivator(LogicalKeyboardKey.keyT, control: true),
                enabled: enabled,
                color: Colors.red,
              ),
            ),
          )
          .then((_) => tester.widget<Text>(find.byType(Text)));
    }

    testWidgets('a supplied color carries into the disabled dim', (
      tester,
    ) async {
      expect((await pumpHint(tester, true)).style!.color, Colors.red);
      expect(
        (await pumpHint(tester, false)).style!.color,
        Colors.red.withValues(alpha: 0.38),
      );
    });
  });

  group('menuAcceleratorLabel', () {
    test('marks the mnemonic, preferring word starts and escaping &', () {
      expect(menuAcceleratorLabel('Save', 's'), '&Save');
      expect(menuAcceleratorLabel('Save As…', 'a'), 'Save &As…');
      expect(menuAcceleratorLabel('Copy Path', 'p'), 'Copy &Path');
      expect(menuAcceleratorLabel('Find', 'n'), 'Fi&nd');
      expect(menuAcceleratorLabel('R&B', 'x'), 'R&&B');
      expect(menuAcceleratorLabel('Résumé', 'z'), 'Résumé');
      expect(menuAcceleratorLabel('İtem', 'i'), '&İtem');
    });
  });

  group('in-window menu rows', () {
    testWidgets('renders enabled/disabled rows, checked state and hints', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: MenuBar(children: ghostMenuBarChildren([menu()]))),
      );
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();

      final newRow = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'New'),
      );
      expect(newRow.onPressed, isNotNull);
      expect(find.text('Ctrl+N'), findsOneWidget);

      final off = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'Off'),
      );
      expect(off.onPressed, isNull);

      expect(find.text('Sort By'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxMenuButton>(
              find.widgetWithText(CheckboxMenuButton, 'Toggle'),
            )
            .value,
        isTrue,
      );
    });
  });
}
