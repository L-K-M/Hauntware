import 'dart:async';

import 'package:flutter/material.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// Clickable status for the app shell. The shared editor keeps its passive
/// default; this bar uses [PlanchetteEditor.statusBuilder] instead.
///
/// Rebuilds from the controller, so the shell holds no metadata state.
/// Line endings and the BOM apply on the next save through `setMetadata`;
/// indentation sets the controller level without dirtying the file.
class DocumentStatusBar extends StatelessWidget {
  const DocumentStatusBar({
    super.key,
    required this.controller,
    this.strings = const EditorStrings(),
  });

  final EditorController controller;
  final EditorStrings strings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => _bar(context),
  );

  Widget _bar(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    final (line, column) = controller.caretLineColumn;
    final selected = controller.selectionStats;
    final passive = [
      if (selected.characters > 0)
        strings.selectionSummary(selected.characters, selected.lines),
      if (controller.isSaving) strings.saving,
      if (controller.isDirty) strings.unsaved,
      strings.languageName(controller.text.language),
      if (!controller.highlightingEnabled) strings.largeFile,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Tooltip(
              message: strings.goToLine,
              child: InkWell(
                onTap: controller.openGoToLine,
                borderRadius: BorderRadius.circular(4),
                child: Text(
                  strings.documentPosition(
                    line,
                    column,
                    controller.lineStarts.length,
                    controller.fileByteCount,
                  ),
                  maxLines: 1,
                  style: style,
                ),
              ),
            ),
            if (controller.problems.isNotEmpty) ...[
              const SizedBox(width: 8),
              EditorProblemStatus(
                controller: controller,
                strings: strings,
                style: style,
              ),
            ],
            for (final label in passive) ...[
              const SizedBox(width: 8),
              Text(label, maxLines: 1, style: style),
            ],
            const SizedBox(width: 8),
            _lineEnding(style),
            const SizedBox(width: 8),
            _encoding(style),
            const SizedBox(width: 8),
            _indentation(style),
          ],
        ),
      ),
    );
  }

  /// Line endings take effect on the next save, not in the buffer.
  Widget _lineEnding(TextStyle? style) {
    final metadata = controller.metadata;
    return PopupMenuButton<LineEnding>(
      tooltip: 'Line endings apply on next save',
      enabled: controller.canChangeMetadata,
      onSelected: (ending) => controller.setMetadata(
        TextDocumentMetadata(
          lineEnding: ending,
          utf8Bom: controller.metadata.utf8Bom,
        ),
      ),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: LineEnding.lf,
          checked: metadata.lineEnding == LineEnding.lf,
          child: const Text('LF'),
        ),
        CheckedPopupMenuItem(
          value: LineEnding.crlf,
          checked: metadata.lineEnding == LineEnding.crlf,
          child: const Text('CRLF'),
        ),
      ],
      child: Text(
        metadata.lineEnding == LineEnding.crlf ? 'CRLF' : 'LF',
        maxLines: 1,
        style: style,
      ),
    );
  }

  /// The BOM is 3 bytes written on the next save.
  Widget _encoding(TextStyle? style) {
    final metadata = controller.metadata;
    return PopupMenuButton<Utf8Bom>(
      tooltip: 'Encoding applies on next save, BOM adds 3 bytes',
      enabled: controller.canChangeMetadata,
      onSelected: (bom) => controller.setMetadata(
        TextDocumentMetadata(
          lineEnding: controller.metadata.lineEnding,
          utf8Bom: bom,
        ),
      ),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: Utf8Bom.absent,
          checked: metadata.utf8Bom == Utf8Bom.absent,
          child: const Text('UTF-8'),
        ),
        CheckedPopupMenuItem(
          value: Utf8Bom.present,
          checked: metadata.utf8Bom == Utf8Bom.present,
          child: const Text('UTF-8 BOM'),
        ),
      ],
      child: Text(
        metadata.utf8Bom == Utf8Bom.present ? 'UTF-8 BOM' : 'UTF-8',
        maxLines: 1,
        style: style,
      ),
    );
  }

  Widget _indentation(TextStyle? style) {
    final current = controller.indentation;
    final tabsRequired =
        requiredIndentationFor(controller.displayPath)?.style ==
        IndentStyle.tabs;
    final canEdit = controller.canEditText;
    return PopupMenuButton<_IndentChoice>(
      tooltip: 'Indentation',
      enabled: controller.canChangeMetadata,
      onSelected: _chooseIndent,
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: _IndentChoice.spaces,
          checked: current.style == IndentStyle.spaces,
          // A tab-mandated format never takes spaces.
          enabled: !tabsRequired,
          child: const Text('Spaces'),
        ),
        CheckedPopupMenuItem(
          value: _IndentChoice.tabs,
          checked: current.style == IndentStyle.tabs,
          child: const Text('Tabs'),
        ),
        const PopupMenuDivider(),
        for (final width in _IndentChoice.widths)
          CheckedPopupMenuItem(
            value: width,
            checked: current.width == width.width,
            // Width keeps the current style, so it is spaces only when
            // spaces are allowed.
            enabled: !tabsRequired || current.style == IndentStyle.tabs,
            child: Text('Width ${width.width}'),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _IndentChoice.convertSpaces,
          enabled: canEdit && !tabsRequired,
          child: const Text('Convert to Spaces'),
        ),
        PopupMenuItem(
          value: _IndentChoice.convertTabs,
          enabled: canEdit,
          child: const Text('Convert to Tabs'),
        ),
      ],
      child: Text(strings.indentation(current), maxLines: 1, style: style),
    );
  }

  void _chooseIndent(_IndentChoice choice) {
    // A popup can outlive the ready state it opened with.
    if (!controller.canChangeMetadata) return;
    final current = controller.indentation;
    switch (choice) {
      case _IndentChoice.spaces:
        if (requiredIndentationFor(controller.displayPath)?.style ==
            IndentStyle.tabs) {
          return;
        }
        controller.indentation = Indentation.spaces(current.width);
      case _IndentChoice.tabs:
        controller.indentation = Indentation.tabs(width: current.width);
      case _IndentChoice.convertSpaces:
        unawaited(controller.runTextTool('convertIndentationToSpaces'));
      case _IndentChoice.convertTabs:
        unawaited(controller.runTextTool('convertIndentationToTabs'));
      case _IndentChoice.width2:
      case _IndentChoice.width4:
      case _IndentChoice.width8:
        controller.indentation = current.style == IndentStyle.tabs
            ? Indentation.tabs(width: choice.width)
            : Indentation.spaces(choice.width);
    }
  }
}

/// Menu choices for the indentation segment. Widths keep the current style,
/// so no boolean parameter decides the outcome.
enum _IndentChoice {
  spaces,
  tabs,
  width2(2),
  width4(4),
  width8(8),
  convertSpaces,
  convertTabs;

  const _IndentChoice([this.width = 0]);

  final int width;

  /// The width entries the menu offers.
  static const widths = [width2, width4, width8];
}
