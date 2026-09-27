import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  const composed = 'caf\u00e9';
  const decomposed = 'cafe\u0301';

  test('comparison modes keep case and normalization axes independent', () {
    expect(
      destinationNameKey('CAF\u00c9', DestinationNameComparison.exact),
      isNot(destinationNameKey(composed, DestinationNameComparison.exact)),
    );
    expect(
      destinationNameKey(decomposed, DestinationNameComparison.exact),
      isNot(destinationNameKey(composed, DestinationNameComparison.exact)),
    );

    expect(
      destinationNameKey(
        'CAF\u00c9',
        DestinationNameComparison.caseInsensitive,
      ),
      destinationNameKey(composed, DestinationNameComparison.caseInsensitive),
    );
    expect(
      destinationNameKey(decomposed, DestinationNameComparison.caseInsensitive),
      isNot(
        destinationNameKey(composed, DestinationNameComparison.caseInsensitive),
      ),
    );

    expect(
      destinationNameKey(decomposed, DestinationNameComparison.normalized),
      destinationNameKey(composed, DestinationNameComparison.normalized),
    );
    expect(
      destinationNameKey('CAF\u00c9', DestinationNameComparison.normalized),
      isNot(destinationNameKey(composed, DestinationNameComparison.normalized)),
    );

    expect(
      destinationNameKey(
        'CAF\u0045\u0301',
        DestinationNameComparison.normalizedCaseInsensitive,
      ),
      destinationNameKey(
        composed,
        DestinationNameComparison.normalizedCaseInsensitive,
      ),
    );
  });

  test('normalizes aliases created by simple case folding', () {
    expect(
      destinationNameKey(
        'J\u030c',
        DestinationNameComparison.normalizedCaseInsensitive,
      ),
      destinationNameKey(
        '\u01f0',
        DestinationNameComparison.normalizedCaseInsensitive,
      ),
    );
  });
}
