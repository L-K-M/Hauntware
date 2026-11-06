import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../family_hues.dart';
import '../main.dart';
import '../services/chat_session.dart';
import '../theme.dart' show SeanceTheme;

/// The assistant view over explicitly selected, isolated conversations.
class ChatSidebar extends StatefulWidget {
  const ChatSidebar({super.key});

  @override
  State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends State<ChatSidebar> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  ChatSession? _draftSession;
  bool _bindingDraft = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AppScope.of(context).chats.initializeSelection();
  }

  @override
  void dispose() {
    _input.removeListener(_saveDraft);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _bindDraft(ChatSession chat) {
    if (!identical(_draftSession, chat)) {
      _input.removeListener(_saveDraft);
      _draftSession = chat;
    } else if (_input.text == chat.draft) {
      return;
    }
    _bindingDraft = true;
    _input.value = TextEditingValue(
      text: chat.draft,
      selection: TextSelection.collapsed(offset: chat.draft.length),
    );
    _bindingDraft = false;
    _input.removeListener(_saveDraft);
    _input.addListener(_saveDraft);
  }

  void _saveDraft() {
    if (!_bindingDraft) _draftSession?.updateDraft(_input.text);
  }

  Future<ChatController> _ensureController(
    AppState state,
    ChatSession chat,
    int turn,
  ) async {
    final version = state.llmConfigVersion;
    final existing = chat.controllerFor(version);
    if (existing != null) return existing;
    final provider = await state.services.buildLlmProvider();
    SearchProvider? search;
    ChatController? controller;
    try {
      if (!chat.isCurrentTurn(turn) || version != state.llmConfigVersion) {
        throw StateError(
          'The assistant settings or conversation changed. Retry.',
        );
      }
      search = await state.services.buildSearchProvider();
      if (!chat.isCurrentTurn(turn) || version != state.llmConfigVersion) {
        throw StateError(
          'The assistant settings or conversation changed. Retry.',
        );
      }
      controller = ChatController(
        provider: provider,
        searchProvider: search,
        redactor: SecretRedactor(
          enabled: state.services.settings.redactionEnabled,
        ),
        onPaste: (_) {},
      );
      chat.adoptController(controller, version);
      return controller;
    } catch (_) {
      if (controller != null) {
        controller.close();
      } else {
        closeLlmProvider(provider);
        if (search != null) closeSearchProvider(search);
      }
      rethrow;
    }
  }

  Future<void> _send(AppState state) async {
    // Everything target-dependent is captured before provider/search creation
    // can yield. Focus changes cannot redirect this turn afterward.
    final store = state.chats;
    final target = store.selectedTarget;
    final chat = store.conversationFor(target);
    final text = chat.draft.trim();
    if (text.isEmpty || chat.sending) return;
    final selectionEpoch = store.selectionEpoch;
    final terminal = target is TerminalChatTarget
        ? state.sessionForChatTarget(target)
        : null;
    final context = terminal != null && state.includeTerminalContext
        ? terminal.engine.recentText(maxLines: 200)
        : null;
    final targetDescription = terminal == null
        ? null
        : terminal.isLocal
        ? 'a local shell — ${target.description}'
        : target.description;
    late final int turn;
    void paste(String command) {
      if (!chat.isCurrentTurn(turn) ||
          store.selectionEpoch != selectionEpoch ||
          terminal == null ||
          !identical(
            state.sessionForChatTarget(target as TerminalChatTarget),
            terminal,
          ) ||
          !identical(state.tabById(terminal.id), terminal) ||
          !terminal.isConnected) {
        throw StateError(
          'The selected terminal changed or disconnected before the command '
          'could be placed. Nothing was pasted.',
        );
      }
      terminal.engine.injectInput(command);
    }

    turn = chat.addUserMessage(text);
    chat.updateDraft('');
    if (identical(_draftSession, chat)) {
      _bindingDraft = true;
      _input.clear();
      _bindingDraft = false;
    }
    _scrollToEnd();

    try {
      final controller = await _ensureController(state, chat, turn);
      if (!chat.isCurrentTurn(turn)) return;
      final result = await controller.send(
        text,
        terminalContext: context,
        sessionTarget: targetDescription,
        onPaste: terminal == null ? null : paste,
        toolScope: terminal == null
            ? ChatToolScope.general
            : ChatToolScope.terminal,
      );
      chat.addReply(turn, result);
    } catch (error) {
      chat.failed(turn, error);
    } finally {
      chat.finishSending(turn);
      if (mounted) _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state.chats,
      builder: (context, _) {
        final target = state.chats.selectedTarget;
        final chat = state.chats.selectedSession;
        final entries = chat.entries;
        _bindDraft(chat);
        return SafeArea(
          child: Column(
            children: [
              _header(context, state, target, chat),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? _ChatEmpty(hasTerminal: target.hasTerminal)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: entries.length,
                        itemBuilder: (context, index) =>
                            _bubble(context, entries[index]),
                      ),
              ),
              if (chat.error != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      chat.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              _composer(context, state, target, chat),
            ],
          ),
        );
      },
    );
  }

  Widget _header(
    BuildContext context,
    AppState state,
    ChatTarget target,
    ChatSession chat,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome,
                size: 20,
                color: FamilyPalette.of(context).glyph(FamilyHue.purple),
              ),
              const SizedBox(width: 8),
              Text('Assistant', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: 'New chat',
                icon: const Icon(Icons.refresh),
                onPressed: chat.isEmpty && chat.draft.isEmpty
                    ? null
                    : chat.reset,
              ),
            ],
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            key: ValueKey('assistant.target.${target.key}'),
            initialValue: target.key,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Conversation target',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final option in state.chats.targets)
                DropdownMenuItem(
                  value: option.key,
                  child: Text(
                    option.hasTerminal
                        ? '${option.label} — ${option.description}'
                        : option.label,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (key) {
              if (key != null) state.chats.select(key);
            },
          ),
          const SizedBox(height: 4),
          Text(
            target.hasTerminal
                ? 'Selected: ${target.description}'
                : 'General: no terminal is selected. Commands cannot be '
                      'placed in a prompt.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _composer(
    BuildContext context,
    AppState state,
    ChatTarget target,
    ChatSession chat,
  ) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListenableBuilder(
            listenable: state,
            builder: (context, _) => FilterChip(
              selected: target.hasTerminal && state.includeTerminalContext,
              label: const Text('Include terminal output'),
              avatar: const Icon(Icons.article_outlined, size: 16),
              onSelected: target.hasTerminal
                  ? state.setIncludeTerminalContext
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      meta: true,
                    ): () =>
                        _send(state),
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): () =>
                        _send(state),
                  },
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Describe a task, or ask a question…',
                      helperText: '⌘/Ctrl + ↵ to send',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(state),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: chat.sending
                    ? 'Waiting for assistant'
                    : 'Send message',
                child: Semantics(
                  label: chat.sending ? 'Sending message' : 'Send message',
                  liveRegion: chat.sending,
                  button: true,
                  child: IconButton.filled(
                    onPressed: chat.sending ? null : () => _send(state),
                    icon: chat.sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, ChatEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: entry.fromUser
            ? Alignment.centerRight
            : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(10),
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.9),
          decoration: BoxDecoration(
            color: entry.fromUser
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(entry.text),
              for (final query in entry.searches)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.search, size: 14),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'searched: $query',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                ),
              for (final command in entry.staged)
                _StagedCommand(command: command),
            ],
          ),
        ),
      ),
    );
  }
}

class _StagedCommand extends StatelessWidget {
  final String command;
  const _StagedCommand({required this.command});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final danger = DangerLinter.worst(command);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: danger == DangerSeverity.critical
            ? Border.all(color: scheme.error)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.keyboard_return, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'placed in prompt: $command',
                  style: SeanceTheme.mono.copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
          if (danger != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      danger == DangerSeverity.critical
                          ? 'Critical — review carefully before running'
                          : 'Review before running',
                      style: TextStyle(fontSize: 11, color: scheme.error),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ChatEmpty extends StatelessWidget {
  final bool hasTerminal;
  const _ChatEmpty({required this.hasTerminal});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 36,
              color: FamilyPalette.of(context).glyph(FamilyHue.purple),
            ),
            const SizedBox(height: 12),
            Text(
              'Describe what you want to do',
              style: Theme.of(context).textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              hasTerminal
                  ? 'Ask about the selected terminal, draft a command for its '
                        'prompt, or search the web. Commands are never run '
                        'automatically.'
                  : 'Ask a general question or search the web. Select an open '
                        'terminal above to share its output or place a command '
                        'in its prompt.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
