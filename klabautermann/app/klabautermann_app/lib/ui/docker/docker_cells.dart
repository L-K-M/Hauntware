import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'images_view.dart' show ImageAgeUnit, imageAge;

// Cells the Images and Volumes sub-tabs share (03 §7.14, §7.15).

/// [age] in words, as `docker images` grades it ([imageAge]).
String dockerAgeText(AppLocalizations l10n, Duration age) =>
    switch (imageAge(age)) {
      (ImageAgeUnit.lessThanMinute, _) => l10n.dockerImagesAgeNow,
      (ImageAgeUnit.minutes, final n) => l10n.dockerImagesAgeMinutes(n),
      (ImageAgeUnit.hours, final n) => l10n.dockerImagesAgeHours(n),
      (ImageAgeUnit.days, final n) => l10n.dockerImagesAgeDays(n),
      (ImageAgeUnit.weeks, final n) => l10n.dockerImagesAgeWeeks(n),
      (ImageAgeUnit.months, final n) => l10n.dockerImagesAgeMonths(n),
      (ImageAgeUnit.years, final n) => l10n.dockerImagesAgeYears(n),
    };

/// A cell's text as the table draws plain cells, on the end edge with
/// tabular figures for a [figure], so sizes line up digit under digit.
class DockerCellText extends StatelessWidget {
  const DockerCellText({super.key, required this.text, this.figure = false});

  final String text;
  final bool figure;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Align(
      alignment: figure
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        textAlign: figure ? TextAlign.end : null,
        style: figure
            ? style?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              )
            : style,
      ),
    );
  }
}

/// An age in words, then its date, muted.
class DockerCreatedCell extends StatelessWidget {
  const DockerCreatedCell({super.key, required this.age, required this.date});

  final String age;
  final String date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      spacing: 8,
      // The smaller date sits on the age's baseline.
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            age,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        Flexible(
          child: Text(
            date,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Whether any container uses an image or volume, as an icon and words, so colour
/// is never the only cue (A11Y-01): "In use (2)", or "Unused", muted.
class DockerUseBadge extends StatelessWidget {
  const DockerUseBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unused = count == 0;
    final color = unused ? theme.colorScheme.onSurfaceVariant : null;
    return Row(
      spacing: 4,
      children: [
        Icon(
          unused ? Icons.link_off : Icons.link,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        Flexible(
          child: Text(
            unused
                ? l10n.dockerImagesUnused
                : l10n.dockerImagesInUseShort(count),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
