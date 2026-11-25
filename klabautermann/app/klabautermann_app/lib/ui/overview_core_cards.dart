part of 'overview_panel.dart';

const double _sparklineHeight = 40;

/// [_sparklineHeight] grown with the text: its scale label is text, and
/// would overflow a fixed height at large sizes.
double _sparklineHeightIn(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(_sparklineHeight);

/// The gap between a gauge and its sparkline, and the least width the
/// sparkline keeps beside it before the gauge stacks above it.
const double _chartsGap = 16;
const double _sparklineMinWidth = 48;

/// The most cores the CPU card draws a bar each for; more read as a
/// [CoreHeatmap], which fits many on a phone (03 §10.7).
const int _coreBarLimit = 16;

/// A per-core bar's width with its figure's box, beside the core's name,
/// before text scaling, and the gap between a core's name, bar and figure.
const double _coreBarAndFigureWidth = 106;
const double _coreGap = 8;

/// The widest a core's name gets before text scaling; only a name no
/// kernel prints, such as a broken host's, is cut there.
const double _coreNameMaxWidth = 72;

/// The trailing number of a `/proc/stat` core name such as `cpu12`.
final RegExp _coreNumber = RegExp(r'\d+$');

/// [perCpu]'s cores in the host's numeric order, `cpu2` before `cpu10`; a
/// name without a number, or with one past any integer, follows the
/// numbered ones. The names are server data, which the host parser takes
/// with any number of digits, so this never throws on them.
List<(String, double)> orderedCores(Map<String, double> perCpu) {
  num number(String name) => switch (_coreNumber.firstMatch(name)) {
    final match? => int.tryParse(match[0]!) ?? double.infinity,
    null => double.infinity,
  };
  return [for (final MapEntry(:key, :value) in perCpu.entries) (key, value)]
    ..sort((a, b) {
      final byNumber = number(a.$1).compareTo(number(b.$1));
      return byNumber != 0 ? byNumber : a.$1.compareTo(b.$1);
    });
}

/// The four cards over one `core` reading.
final class _Cards {
  const _Cards({
    required this.monitoring,
    required this.serverId,
    required this.core,
    required this.stale,
  });

  final MonitoringController monitoring;
  final String serverId;
  final CoreResult core;
  final bool stale;

  /// SYS-04's reason, or [text], when the engine withheld any of [fields]
  /// as the container host's (D50); their values are then null.
  Widget? _withheld(
    AppLocalizations l10n,
    List<MetricField> fields, {
    String? text,
  }) => fields.any(core.withheld.containsKey)
      ? PanelNotice(
          icon: Icons.info_outline,
          text: text ?? l10n.overviewUnknownContainer,
        )
      : null;

  /// [series]' gauge of [value] out of [total] beside its session
  /// sparkline. The sparkline's bands are in its own unit, so it takes
  /// [thresholds] only for a share; the gauge judges [value]'s share of
  /// [total].
  Widget _charts(
    BuildContext context, {
    required MetricSeries series,
    required String label,
    required String part,
    required ChartUnit unit,
    required double? value,
    required double? total,
    ChartThresholds? thresholds,
  }) {
    final strings = klabautermannChartStrings(AppLocalizations.of(context));
    final gauge = Gauge(
      label: label,
      part: part,
      value: value,
      total: total,
      unit: unit,
      strings: strings,
      thresholds: thresholds,
      stale: stale,
    );
    final sparkline = SizedBox(
      height: _sparklineHeightIn(context),
      child: Sparkline(
        series: monitoring.seriesFor(serverId, SampleStream.core, series),
        label: label,
        unit: unit,
        strings: strings,
        max: total != null && total > 0 ? total : null,
        thresholds: unit == ChartUnit.percent ? thresholds : null,
        color: stale ? ChartPalette.of(context).muted : null,
      ),
    );
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The words under the arc grow with the text and with a severity;
        // when they leave the sparkline too little room, it goes below.
        final gaugeWidth = scaler.scale(Gauge.legendWidth);
        if (gaugeWidth + _chartsGap + _sparklineMinWidth >
            constraints.maxWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: _chartsGap,
            children: [
              Align(alignment: AlignmentDirectional.centerStart, child: gauge),
              sparkline,
            ],
          );
        }

        return Row(
          spacing: _chartsGap,
          children: [
            gauge,
            Expanded(child: sparkline),
          ],
        );
      },
    );
  }

  Widget cpu(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final strings = klabautermannChartStrings(l10n);
    final cpu = core.cpu;
    final perCpu = core.perCpu;
    String? percent(double? value) => value == null
        ? null
        : formatChartValue(value, ChartUnit.percent, strings);
    return PanelSection(
      title: l10n.overviewCpuTitle,
      children: [
        _charts(
          context,
          series: MetricSeries.cpuBusy,
          label: l10n.overviewCpuTitle,
          part: l10n.overviewCpuBusy,
          unit: ChartUnit.percent,
          value: cpu?.busy,
          total: 100,
          thresholds: ThresholdScope.of(context, ThresholdMetric.cpu),
        ),
        _Facts(
          stale: stale,
          facts: [
            (l10n.overviewCpuUser, percent(cpu?.user)),
            (l10n.overviewCpuSystem, percent(cpu?.system)),
            (l10n.overviewCpuIdle, percent(cpu?.idle)),
            (l10n.overviewCpuIowait, percent(cpu?.iowait)),
            (l10n.overviewCpuSteal, percent(cpu?.steal)),
            (l10n.overviewCpuIrq, percent(cpu?.irq)),
            (l10n.overviewCpuSoftirq, percent(cpu?.softirq)),
          ],
        ),
        // CPU-04's hints explain what the figures above mean for the
        // host; a stale reading keeps them beside the greyed figures.
        if (cpu != null)
          for (final hint in cpuHints(cpu))
            PanelNotice(
              icon: Icons.lightbulb_outline,
              text: _hintText(l10n, hint, percent(hint.percent)!),
            ),
        Semantics(
          header: true,
          child: Text(
            l10n.overviewPerCoreTitle,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        if (perCpu == null || perCpu.isEmpty)
          _Facts(stale: stale, facts: const [])
        else if (perCpu.length > _coreBarLimit)
          CoreHeatmap(
            label: l10n.overviewPerCoreTitle,
            cores: orderedCores(perCpu),
            strings: strings,
            stale: stale,
          )
        else
          _CoreBars(cores: orderedCores(perCpu), stale: stale),
        // One note for the card: a container withholds both from the same
        // /proc/stat, so two would repeat each other.
        ?_withheld(l10n, const [MetricField.cpu, MetricField.perCpu]),
      ],
    );
  }

  static String _hintText(
    AppLocalizations l10n,
    CpuHint hint,
    String percent,
  ) => switch (hint.kind) {
    CpuHintKind.steal => l10n.overviewCpuHintSteal(percent),
    CpuHintKind.iowait => l10n.overviewCpuHintIowait(percent),
    CpuHintKind.interrupts => l10n.overviewCpuHintInterrupts(percent),
  };

  /// TRI-02: what in this reading slows the server, each in a sentence,
  /// and where to look next.
  Widget slowness(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final strings = klabautermannChartStrings(l10n);
    String percent(double value) =>
        formatChartValue(value, ChartUnit.percent, strings);
    final signals = slownessSignals(core);
    return PanelSection(
      title: l10n.overviewSlowTitle,
      children: [
        if (signals.isEmpty)
          Text(l10n.overviewSlowNone, style: _valueStyle(context, stale))
        else ...[
          for (final signal in signals)
            PanelNotice(
              icon: Icons.speed,
              text: switch (signal.kind) {
                SlownessKind.cpuWait => l10n.overviewSlowCpuWait(
                  percent(signal.value),
                ),
                SlownessKind.loadHigh => l10n.overviewSlowLoadHigh(
                  signal.value,
                ),
                SlownessKind.steal => l10n.overviewSlowSteal(
                  percent(signal.value),
                ),
                SlownessKind.ioStall => l10n.overviewSlowIoStall(
                  percent(signal.value),
                ),
                SlownessKind.iowait => l10n.overviewSlowIowait(
                  percent(signal.value),
                ),
                SlownessKind.slowDisk => l10n.overviewSlowSlowDisk(
                  signal.device!,
                  signal.value.round(),
                ),
                SlownessKind.busyDisk => l10n.overviewSlowBusyDisk(
                  signal.device!,
                  percent(signal.value),
                ),
                SlownessKind.memoryStall => l10n.overviewSlowMemoryStall(
                  percent(signal.value),
                ),
                SlownessKind.swapHeavy => l10n.overviewSlowSwapHeavy(
                  percent(signal.value),
                ),
              },
            ),
          Text(
            l10n.overviewSlowWhere,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  /// CPU-05 and MEM-04: how much of the time tasks stalled for CPU,
  /// memory and I/O. A kernel without PSI is normal (7.1), so its absence
  /// is said plainly rather than as a failure.
  Widget pressure(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Two decimals as the kernel prints them: stalls of a fraction of a
    // percent are the usual reading, which whole percents would zero.
    String? averages(StallAverages? line) => line == null
        ? null
        : l10n.overviewPressureValue(line.avg10, line.avg60, line.avg300);

    const fields = [
      MetricField.cpuPressure,
      MetricField.memoryPressure,
      MetricField.ioPressure,
    ];
    final files = [
      (l10n.overviewPressureCpu, core.cpuPressure),
      (l10n.overviewPressureMemory, core.memoryPressure),
      (l10n.overviewPressureIo, core.ioPressure),
    ];
    final withheld = _withheld(l10n, fields);
    final figures = [
      for (final (name, file) in files)
        if (file != null) ...[
          if (file.some != null)
            (l10n.overviewPressureSome(name), averages(file.some)),
          if (file.full != null)
            (l10n.overviewPressureFull(name), averages(file.full)),
        ],
    ];
    return PanelSection(
      title: l10n.overviewPressureTitle,
      children: [
        // A container without its own pressure files withholds them all:
        // the reason then stands alone, without a caption over nothing.
        if (figures.isNotEmpty) ...[
          Text(
            l10n.overviewPressureCaption,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          _Facts(stale: stale, facts: figures),
        ] else if (withheld == null)
          Text(l10n.overviewPressureNone, style: _valueStyle(context, stale)),
        ?withheld,
      ],
    );
  }

  Widget load(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final load = core.load;
    String? figure(double? value) =>
        value == null ? null : l10n.overviewLoadValue(value);
    return PanelSection(
      title: l10n.overviewLoadTitle,
      children: [
        SizedBox(
          height: _sparklineHeightIn(context),
          child: Sparkline(
            series: monitoring.seriesFor(
              serverId,
              SampleStream.core,
              MetricSeries.load1,
            ),
            label: l10n.overviewLoadSparkline,
            unit: ChartUnit.decimal,
            strings: klabautermannChartStrings(l10n),
            showScale: true,
            color: stale ? ChartPalette.of(context).muted : null,
          ),
        ),
        _Facts(
          stale: stale,
          facts: [
            (l10n.overviewLoad1, figure(load?.load1)),
            (l10n.overviewLoad5, figure(load?.load5)),
            (l10n.overviewLoad15, figure(load?.load15)),
            (l10n.overviewLoadPerCore, figure(core.loadPerCore)),
          ],
        ),
        // The averages come from /proc/loadavg; with only the per-core
        // figure withheld, they show and its core count is the host's.
        ?(_withheld(l10n, const [MetricField.load]) ??
            _withheld(l10n, const [
              MetricField.loadPerCore,
            ], text: l10n.overviewUnknownContainerLoadPerCore)),
      ],
    );
  }

  /// [value] in the chart formatters' IEC units, null when unknown.
  static String? _bytes(AppLocalizations l10n, int? value) => value == null
      ? null
      : formatChartValue(
          value.toDouble(),
          ChartUnit.bytes,
          klabautermannChartStrings(l10n),
        );

  Widget memory(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final memory = core.memory;
    String? bytes(int? value) => _bytes(l10n, value);
    return PanelSection(
      title: l10n.overviewMemoryTitle,
      children: [
        // Only used is drawn: it is the total less MemAvailable, which
        // counts no shared memory and keeps some cache back, so buffers
        // and cache overlap it and would stack past what is taken.
        _charts(
          context,
          series: MetricSeries.memoryUsed,
          label: l10n.overviewMemoryTitle,
          part: l10n.overviewMemoryUsed,
          unit: ChartUnit.bytes,
          value: memory?.usedBytes?.toDouble(),
          total: memory?.totalBytes?.toDouble(),
          thresholds: ThresholdScope.of(context, ThresholdMetric.memory),
        ),
        _Facts(
          stale: stale,
          facts: [
            (l10n.overviewMemoryTotal, bytes(memory?.totalBytes)),
            (l10n.overviewMemoryAvailable, bytes(memory?.availableBytes)),
            (l10n.overviewMemoryBuffers, bytes(memory?.buffersBytes)),
            (l10n.overviewMemoryCache, bytes(memory?.cachedBytes)),
            (l10n.overviewMemoryShared, bytes(memory?.sharedBytes)),
          ],
        ),
        if (memory?.zfsArcCountedAsUsed ?? false)
          PanelNotice(icon: Icons.info_outline, text: l10n.overviewMemoryArc),
        ?_withheld(l10n, const [MetricField.memory]),
      ],
    );
  }

  /// NET-01's total rates over every interface the host reported; the
  /// first reading after a start or a counter reset has none.
  Widget network(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final strings = klabautermannChartStrings(l10n);
    final totals = networkTotals(core.network);
    String? rate(double? value) => value == null
        ? null
        : formatChartValue(value, ChartUnit.bytesPerSecond, strings);
    return PanelSection(
      title: l10n.systemNetworkTitle,
      children: [
        _Facts(
          stale: stale,
          facts: [
            (l10n.systemReceive, rate(totals?.rx)),
            (l10n.systemTransmit, rate(totals?.tx)),
          ],
        ),
      ],
    );
  }

  Widget swap(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final memory = core.memory;
    final total = memory?.swapTotalBytes;
    return PanelSection(
      title: l10n.overviewSwapTitle,
      children: [
        if (total == 0)
          Text(l10n.overviewSwapNone, style: _valueStyle(context, stale))
        else ...[
          _charts(
            context,
            series: MetricSeries.swapUsed,
            label: l10n.overviewSwapTitle,
            part: l10n.overviewMemoryUsed,
            unit: ChartUnit.bytes,
            value: memory?.swapUsedBytes?.toDouble(),
            total: total?.toDouble(),
          ),
          _Facts(
            stale: stale,
            facts: [(l10n.overviewMemoryTotal, _bytes(l10n, total))],
          ),
        ],
        ?_withheld(l10n, const [MetricField.memory]),
      ],
    );
  }
}

/// Each core's busy share as a bar beside its name and figure, read as
/// "cpu0 12%"; they wrap into as many columns as the card holds.
class _CoreBars extends StatelessWidget {
  const _CoreBars({required this.cores, required this.stale});

  final List<(String, double)> cores;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final strings = klabautermannChartStrings(l10n);
    final scaler = MediaQuery.textScalerOf(context);
    final style = _valueStyle(context, stale);
    // Every name gets the longest one's width on one line, so `cpu100`
    // does not wrap into what reads as a lower core and the bars line up.
    // Measured in the style `Text` resolves, bold text included.
    var nameStyle = DefaultTextStyle.of(context).style.merge(style);
    if (MediaQuery.boldTextOf(context)) {
      nameStyle = nameStyle.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    double measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: nameStyle),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width.ceilToDouble();
    }

    final nameWidth = cores.fold(
      0.0,
      (widest, core) => math.max(
        widest,
        math.min(measure(core.$1), scaler.scale(_coreNameMaxWidth)),
      ),
    );
    // Every figure gets the widest one's room, so its digits take none of
    // its bar's length and the bars compare across cores. That room comes
    // out of the bar, not the row, so the boxes cost no column of cores on
    // a narrow phone.
    final figureWidth = measure(
      formatChartValue(100, ChartUnit.percent, strings),
    );
    return Wrap(
      spacing: _gap,
      runSpacing: 8,
      children: [
        for (final (name, value) in cores)
          SizedBox(
            width: nameWidth + _coreGap + scaler.scale(_coreBarAndFigureWidth),
            child: MergeSemantics(
              child: Row(
                spacing: _coreGap,
                children: [
                  SizedBox(
                    width: nameWidth,
                    child: Text(
                      name,
                      style: style,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: ExcludeSemantics(
                      child: StackedBar(
                        label: name,
                        segments: [
                          BarSegment(label: l10n.overviewCpuBusy, value: value),
                        ],
                        total: 100,
                        unit: ChartUnit.percent,
                        strings: strings,
                        stale: stale,
                        showLegend: false,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: figureWidth,
                    child: Text(
                      formatChartValue(value, ChartUnit.percent, strings),
                      style: style,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Value text, grey while stale (03 §9.5 item 4), in tabular figures.
TextStyle? _valueStyle(BuildContext context, bool stale) {
  final theme = Theme.of(context);
  return theme.textTheme.bodyMedium?.copyWith(
    color: stale ? theme.colorScheme.onSurfaceVariant : null,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// Labelled figures side by side, wrapping at large text, each read as one
/// node. Null reads "Unknown", never zero (03 §10.4), as do no facts at
/// all.
class _Facts extends StatelessWidget {
  const _Facts({required this.stale, required this.facts});

  final bool stale;
  final List<(String, String?)> facts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final style = _valueStyle(context, stale);
    if (facts.isEmpty) return Text(l10n.overviewUnknown, style: style);

    return Wrap(
      spacing: 24,
      runSpacing: 8,
      children: [
        for (final (label, value) in facts)
          MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(value ?? l10n.overviewUnknown, style: style),
              ],
            ),
          ),
      ],
    );
  }
}
