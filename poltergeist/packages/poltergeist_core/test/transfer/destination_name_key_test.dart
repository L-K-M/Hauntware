import 'package:poltergeist_core/src/transfer/destination_name_key.dart';
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

  test('normalizes aliases created during case folding', () {
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

  test('keeps exact trait keys narrower than the conservative key', () {
    for (final comparison in const [
      DestinationNameComparison.caseInsensitive,
      DestinationNameComparison.normalizedCaseInsensitive,
    ]) {
      expect(
        destinationNameKey('stra\u00dfe.txt', comparison),
        isNot(destinationNameKey('strasse.txt', comparison)),
      );
      expect(
        destinationNameKey('soft\u00adhyphen.txt', comparison),
        isNot(destinationNameKey('softhyphen.txt', comparison)),
      );
    }

    expect(
      conservativeDestinationNameKey('stra\u00dfe.txt'),
      conservativeDestinationNameKey('strasse.txt'),
    );
    expect(
      conservativeDestinationNameKey('soft\u00adhyphen.txt'),
      conservativeDestinationNameKey('softhyphen.txt'),
    );
  });

  test('keeps NTFS and exFAT dotless i distinct from ASCII i', () {
    expect(
      destinationNameKey(
        'file\u0131.txt',
        DestinationNameComparison.caseInsensitive,
      ),
      isNot(
        destinationNameKey(
          'filei.txt',
          DestinationNameComparison.caseInsensitive,
        ),
      ),
    );
  });
}
