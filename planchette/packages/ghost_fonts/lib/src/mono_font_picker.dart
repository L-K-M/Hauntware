import 'package:flutter/material.dart';

import 'bundled_mono_font.dart';
import 'mono_ligatures.dart';

/// A confirmed choice. An empty family follows the host's default.
@immutable
class MonoFontSelection {
  const MonoFontSelection({required this.family, required this.ligatures});

  final String family;
  final MonoLigatures ligatures;
}

/// Hosts supply localized copy without coupling this leaf UI to an app.
@immutable
class MonoFontPickerLabels {
  const MonoFontPickerLabels({
    this.title = 'Choose a font',
    this.search = 'Search fonts',
    this.included = 'Included fonts',
    this.installed = 'Installed fonts',
    this.empty = 'No fonts match your search.',
    this.ligatures = 'Ligatures',
    this.apply = 'Use font',
    this.cancel = 'Cancel',
    this.defaultLabel = 'default',
    this.monospaceOnly = 'Monospace only',
    this.preview = 'Preview',
    this.noLigatures = 'This font has no programming ligatures.',
  });

  final String title;
  final String search;
  final String included;
  final String installed;
  final String empty;
  final String ligatures;
  final String apply;
  final String cancel;
  final String defaultLabel;
  final String monospaceOnly;
  final String preview;
  final String noLigatures;
}

/// Search bundled and optional installed families, then inspect before applying.
/// Scanning belongs to the host; bundled choices remain usable while it runs.
Future<MonoFontSelection?> showMonoFontPicker(
  BuildContext context, {
  required String current,
  required BundledMonoFont defaultFont,
  MonoLigatures ligatures = MonoLigatures.on,
  double fontSize = 14,
  Future<Map<String, bool>> Function()? installedFonts,
  MonoFontPickerLabels labels = const MonoFontPickerLabels(),
  Widget Function(String family, MonoLigatures ligatures)? previewBuilder,
}) => showDialog<MonoFontSelection>(
  context: context,
  builder: (_) => _MonoFontPicker(
    current: current,
    defaultFont: defaultFont,
    ligatures: ligatures,
    fontSize: fontSize,
    installedFonts: installedFonts,
    labels: labels,
    previewBuilder: previewBuilder,
  ),
);

class _MonoFontPicker extends StatefulWidget {
  const _MonoFontPicker({
    required this.current,
    required this.defaultFont,
    required this.ligatures,
    required this.fontSize,
    required this.installedFonts,
    required this.labels,
    required this.previewBuilder,
  });

  final String current;
  final BundledMonoFont defaultFont;
  final MonoLigatures ligatures;
  final double fontSize;
  final Future<Map<String, bool>> Function()? installedFonts;
  final MonoFontPickerLabels labels;
  final Widget Function(String family, MonoLigatures ligatures)? previewBuilder;

  @override
  State<_MonoFontPicker> createState() => _MonoFontPickerState();
}

class _MonoFontPickerState extends State<_MonoFontPicker> {
  static const _wideLayout = 680.0;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late String _family =
      BundledMonoFont.named(widget.current) == widget.defaultFont
      ? ''
      : widget.current.trim();
  late MonoLigatures _ligatures = widget.ligatures;
  Map<String, bool> _installed = const {};
  bool _scanning = false;
  bool _monospaceOnly = true;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final load = widget.installedFonts;
    if (load == null) return;
    _scanning = true;
    try {
      final fonts = await load();
      if (mounted) setState(() => _installed = fonts);
    } catch (error, trace) {
      debugPrint('Font scan failed: $error\n$trace');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _resolved =>
      _family.isEmpty ? widget.defaultFont.family : resolveMonoFamily(_family);

  String get _name => _family.isEmpty
      ? widget.defaultFont.displayName
      : BundledMonoFont.named(_family)?.displayName ?? _family;

  List<({String name, String value, String section})> _choices() {
    final labels = widget.labels;
    final query = _search.text.trim().toLowerCase();
    final bundled = [...BundledMonoFont.values]
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    final installed = {..._installed};
    // A typed or no-longer-installed family must survive opening the picker.
    if (widget.current.trim().isNotEmpty &&
        BundledMonoFont.named(widget.current) == null &&
        !installed.keys.any(
          (name) => name.toLowerCase() == widget.current.trim().toLowerCase(),
        )) {
      installed.putIfAbsent(widget.current.trim(), () => true);
    }
    final names = installed.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [
      for (final choice in [
        (
          name: '${widget.defaultFont.displayName} (${labels.defaultLabel})',
          value: '',
          section: labels.included,
        ),
        for (final font in bundled)
          if (font != widget.defaultFont)
            (
              name: font.displayName,
              value: font.displayName,
              section: labels.included,
            ),
        for (final name in names)
          if (BundledMonoFont.named(name) == null &&
              (!_monospaceOnly ||
                  installed[name]! ||
                  name.toLowerCase() == widget.current.trim().toLowerCase()))
            (name: name, value: name, section: labels.installed),
      ])
        if (choice.name.toLowerCase().contains(query)) choice,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 900,
        height: MediaQuery.sizeOf(context).width < _wideLayout
            ? MediaQuery.sizeOf(context).height
            : 640,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(labels.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('font.search'),
                controller: _search,
                onChanged: (_) {
                  setState(() {});
                  if (_scroll.hasClients) _scroll.jumpTo(0);
                },
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: labels.search,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (widget.installedFonts != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilterChip(
                    label: Text(labels.monospaceOnly),
                    selected: _monospaceOnly,
                    onSelected: (value) =>
                        setState(() => _monospaceOnly = value),
                  ),
                ),
              const SizedBox(height: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final layout = constraints.maxWidth < _wideLayout
                        ? _PickerLayout.compact
                        : _PickerLayout.wide;
                    final choices = _choices();
                    final list = _list(choices, layout: layout);
                    if (layout == _PickerLayout.compact) return list;

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 260, child: list),
                        const SizedBox(width: 16),
                        Expanded(child: _preview()),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (_scanning)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(labels.cancel),
                  ),
                  FilledButton(
                    key: const ValueKey('font.apply'),
                    onPressed: () => Navigator.of(context).pop(
                      MonoFontSelection(family: _family, ligatures: _ligatures),
                    ),
                    child: Text(labels.apply),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(
    List<({String name, String value, String section})> choices, {
    required _PickerLayout layout,
  }) {
    final rows = <Widget Function()>[
      // Keep search results immediately reachable above a phone keyboard.
      if (layout == _PickerLayout.compact && _search.text.trim().isEmpty)
        () => _preview(),
      if (choices.isEmpty)
        () => Padding(
          padding: const EdgeInsets.all(24),
          child: Text(widget.labels.empty),
        ),
      for (final (index, choice) in choices.indexed) ...[
        if (index == 0 || choices[index - 1].section != choice.section)
          () => Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 12, 4),
            child: Text(
              choice.section,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        () => _row(choice, layout: layout),
      ],
    ];
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: ListView.builder(
        key: const ValueKey('font.list'),
        controller: _scroll,
        itemCount: rows.length,
        itemBuilder: (_, index) => rows[index](),
      ),
    );
  }

  Widget _row(
    ({String name, String value, String section}) choice, {
    required _PickerLayout layout,
  }) {
    final selected = choice.value.toLowerCase() == _family.toLowerCase();
    final family = choice.value.isEmpty
        ? widget.defaultFont.family
        : resolveMonoFamily(choice.value);
    return Semantics(
      selected: selected,
      child: ListTile(
        key: ValueKey('font.choice.${choice.value}'),
        selected: selected,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Text(choice.name),
        subtitle: ExcludeSemantics(
          child: Text(
            'Il1 0O  -> != ===',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: family,
              fontFamilyFallback: ghostMonoFontFamilies,
              fontFeatures: _ligatures.featuresFor(family),
            ),
          ),
        ),
        trailing: selected ? const Icon(Icons.check) : null,
        onTap: () {
          setState(() {
            _family = choice.value;
            if (layout == _PickerLayout.compact) _search.clear();
          });
          // On phones the detail sits above the list; bring the new sample
          // back into view instead of leaving the change off screen.
          if (layout == _PickerLayout.compact) {
            FocusScope.of(context).unfocus();
            _scroll.animateTo(
              0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
            );
          }
        },
      ),
    );
  }

  Widget _preview() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.labels.preview,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              Text(_name, style: Theme.of(context).textTheme.titleMedium),
              SwitchListTile(
                key: const ValueKey('font.ligatures'),
                contentPadding: EdgeInsets.zero,
                title: Text(widget.labels.ligatures),
                subtitle:
                    BundledMonoFont.named(_name)?.hasProgrammingLigatures ==
                        false
                    ? Text(widget.labels.noLigatures)
                    : null,
                value: _ligatures == MonoLigatures.on,
                onChanged: (value) => setState(
                  () =>
                      _ligatures = value ? MonoLigatures.on : MonoLigatures.off,
                ),
              ),
              const Divider(),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child:
                    widget.previewBuilder?.call(_resolved, _ligatures) ??
                    MonoFontPreview(
                      family: _resolved,
                      fontSize: widget.fontSize,
                      ligatures: _ligatures,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _PickerLayout { compact, wide }

/// Code, ambiguous glyphs and emphasis using the same shaping as the editor.
class MonoFontPreview extends StatelessWidget {
  const MonoFontPreview({
    super.key,
    required this.family,
    this.fontSize = 14,
    this.ligatures = MonoLigatures.on,
  });

  final String family;
  final double fontSize;
  final MonoLigatures ligatures;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: const [
        TextSpan(text: 'const ready = value != null;\n'),
        TextSpan(text: 'if (ready && count >= 10) {\n'),
        TextSpan(text: '  return items.map((x) => x + 1);\n}\n\n'),
        TextSpan(text: 'Il1 | 0Oo  {} [] ()  @ # &\n'),
        TextSpan(text: '-> => != === <= >= </>\n\n'),
        TextSpan(
          text: 'Aa Bb 0123  ',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        TextSpan(
          text: 'Aa Bb 0123\n',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
        TextSpan(
          text: 'Aa Bb 0123',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    ),
    key: const ValueKey('font.sample'),
    style: TextStyle(
      fontFamily: family,
      fontFamilyFallback: ghostMonoFontFamilies,
      fontSize: fontSize,
      height: 1.4,
      fontFeatures: ligatures.featuresFor(family),
      color: Theme.of(context).colorScheme.onSurface,
    ),
  );
}
