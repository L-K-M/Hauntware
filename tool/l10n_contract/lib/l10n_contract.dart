/// Shared localization contract scanner for the Hauntware suite apps.
///
/// The scanner rejects authored user-facing string literals outside the
/// ARB catalog. Generated output, generated localization, and per-file
/// reviewed technical exceptions are excluded; every exception must stay
/// live, and a source that fails to parse fails the gate instead of
/// hiding literals.
library;

export 'src/localization_contract.dart';
