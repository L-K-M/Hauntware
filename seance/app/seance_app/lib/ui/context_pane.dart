import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../family_hues.dart';
import '../main.dart';
import '../services/external_file_opener.dart';
import '../services/local_reveal.dart';
import '../services/terminal_context.dart';
import '../services/web_links.dart';
import '../theme.dart' show SeanceTheme;
import 'middle_ellipsis_text.dart';
import 'top_toast.dart';

/// The Context tab: links and file paths the active session's output has
/// shown, newest first, each with what can be done with it here, as Mac
/// data detectors and kitty's hints offer. A link opens in the browser; a
/// path a local shell printed opens or shows in the file manager, and one a
/// server printed shows in Files. Any of them can be copied or typed at the
/// prompt. Nothing runs on the server.
class ContextPane extends StatelessWidget {
  const ContextPane({super.key, required this.showFiles});

  /// Brings the Files tab (or screen) forward, for Show in Files.
  final VoidCallback showFiles;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final session = state.activeSession;
        return Column(
          children: [
            _Header(stack: session?.contextStack),
            const Divider(height: 1),
            Expanded(
              child: session == null
                  ? const _Message(
                      title: 'No session',
                      body:
                          'Open a terminal session to collect the links and '
                          'paths it shows.',
                    )
                  : _ContextList(
                      key: ValueKey(session.id),
                      session: session,
                      showFiles: showFiles,
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.stack});

  final TerminalContextStack? stack;

  @override
  Widget build(BuildContext context) {
    final stack = this.stack;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          Icon(
            Icons.dataset_linked,
            size: 20,
            color: FamilyPalette.of(context).glyph(FamilyHue.cyan),
          ),
          const SizedBox(width: 8),
          Text('Context', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (stack != null)
            ListenableBuilder(
              listenable: stack,
              builder: (context, _) => IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.clear_all),
                onPressed: stack.items.isEmpty ? null : stack.clear,
              ),
            ),
        ],
      ),
    );
  }
}

/// What a row offers, in menu order. The first one a row has is what a tap
/// does; every row ends its menu with [remove].
enum _ContextAction {
  openLink,
  openFile,
  reveal,
  showInFiles,
  copy,
  insert,
  remove,
}

class _ContextList extends StatelessWidget {
  const _ContextList({
    super.key,
    required this.session,
    required this.showFiles,
  });

  final TerminalSession session;
  final VoidCallback showFiles;

  @override
  Widget build(BuildContext context) {
    final stack = session.contextStack;
    return ListenableBuilder(
      listenable: stack,
      builder: (context, _) {
        final items = stack.items;
        if (items.isEmpty) {
          return const _Message(
            title: 'Nothing recognised yet',
            body:
                'Links and file paths this session shows collect here, '
                'with what you can do with each.',
          );
        }
        return ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _ContextRow(
            item: items[i],
            actions: _actionsFor(items[i]),
            onAction: (action) => _run(context, items[i], action),
          ),
        );
      },
    );
  }

  List<_ContextAction> _actionsFor(ContextItem item) => switch (item.kind) {
    ContextKind.url => const [
      _ContextAction.openLink,
      _ContextAction.copy,
      _ContextAction.insert,
    ],
    // A local shell's paths are on this machine. A server's are not, and
    // Files is where this app reaches them. A tap only shows a local file:
    // opening one a server named is a choice, made from the menu.
    ContextKind.path when session.isLocal => const [
      _ContextAction.reveal,
      _ContextAction.openFile,
      _ContextAction.copy,
      _ContextAction.insert,
    ],
    ContextKind.path => const [
      _ContextAction.showInFiles,
      _ContextAction.copy,
      _ContextAction.insert,
    ],
  };

  Future<void> _run(
    BuildContext context,
    ContextItem item,
    _ContextAction action,
  ) async {
    void say(String message) => showTopToastIn(context, message: message);
    try {
      switch (action) {
        case _ContextAction.openLink:
          if (!await openWebLink(Uri.parse(item.value))) {
            say('Could not open link.');
          }
        case _ContextAction.openFile:
          await _openLocal(item.value);
        case _ContextAction.reveal:
          await const LocalFileReveal().reveal(item.value);
        case _ContextAction.showInFiles:
          final files = session.files;
          if (!session.isConnected || files == null) {
            say('Reconnect this session to browse its files.');
            return;
          }
          // Files comes forward once the server has found the path, so a
          // path that only looked like one is reported here.
          await files.reveal(item.value);
          showFiles();
        case _ContextAction.copy:
          await Clipboard.setData(ClipboardData(text: item.value));
          say(item.kind == ContextKind.url ? 'Copied link' : 'Copied path');
        case _ContextAction.insert:
          _insert(item, say);
        case _ContextAction.remove:
          session.contextStack.remove(item);
      }
    } on StateError catch (e) {
      say(e.message);
    } catch (e) {
      say(e.toString());
    }
  }

  /// Hands a local file to the system's default app, unless that would run
  /// it. The name check (`ExternalFileOpener`) knows extensions; a program
  /// without one (`/usr/bin/ls`, a script with its execute bit) is caught
  /// by its mode instead, since macOS's `open` runs it in Terminal.
  static Future<void> _openLocal(String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) {
      throw StateError('$path does not exist on this computer.');
    }
    if (stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0) {
      throw ExecutableLaunchRefused(path);
    }
    await const ExternalFileOpener().openSystemDefault(path);
  }

  /// Types the item at the prompt as one shell word, without Enter: a link's
  /// `&` or a path's space must not split it or start a second command.
  void _insert(ContextItem item, void Function(String) say) {
    if (!session.isConnected) {
      say('Reconnect this session first.');
      return;
    }
    final value = item.value;
    final word = value.startsWith('~/')
        ? '~/${_shellWord(value.substring(2))}'
        : _shellWord(value);
    final String text;
    try {
      text = PasteSanitizer.sanitize(word);
    } on UnsafePasteException catch (e) {
      say(e.reason);
      return;
    }
    session.engine.injectInput(text);
  }

  /// [value] as is when every shell reads it as one literal word, quoted
  /// otherwise, so the common path stays readable at the prompt.
  static String _shellWord(String value) =>
      _plainWord.hasMatch(value) ? value : quoteShellWord(value);

  static final _plainWord = RegExp(r'^[\w@%+=:,./-]+$');
}

class _ContextRow extends StatelessWidget {
  const _ContextRow({
    required this.item,
    required this.actions,
    required this.onAction,
  });

  final ContextItem item;
  final List<_ContextAction> actions;
  final ValueChanged<_ContextAction> onAction;

  static String _label(_ContextAction action) => switch (action) {
    _ContextAction.openLink => 'Open in Browser',
    _ContextAction.openFile => 'Open',
    _ContextAction.reveal => LocalFileReveal.actionLabel,
    _ContextAction.showInFiles => 'Show in Files',
    _ContextAction.copy => 'Copy',
    _ContextAction.insert => 'Insert at Prompt',
    _ContextAction.remove => 'Remove',
  };

  @override
  Widget build(BuildContext context) {
    final palette = FamilyPalette.of(context);
    final isUrl = item.kind == ContextKind.url;
    final showsValue = item.label != item.value;
    return ListTile(
      dense: true,
      leading: Icon(
        isUrl ? Icons.link : Icons.description_outlined,
        size: 20,
        color: palette.glyph(isUrl ? FamilyHue.cyan : FamilyHue.graphite),
      ),
      title: MiddleEllipsisText(
        item.label,
        style: SeanceTheme.mono.copyWith(fontSize: 13),
      ),
      // A relative path shows where it resolved to.
      subtitle: showsValue
          ? MiddleEllipsisText(
              item.value,
              style: Theme.of(context).textTheme.bodySmall,
            )
          : null,
      onTap: () => onAction(actions.first),
      trailing: PopupMenuButton<_ContextAction>(
        tooltip: 'Actions',
        onSelected: onAction,
        itemBuilder: (_) => [
          for (final action in actions)
            PopupMenuItem(value: action, child: Text(_label(action))),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: _ContextAction.remove,
            child: Text(_label(_ContextAction.remove)),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dataset_linked,
              size: 36,
              color: FamilyPalette.of(context).glyph(FamilyHue.cyan),
            ),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
