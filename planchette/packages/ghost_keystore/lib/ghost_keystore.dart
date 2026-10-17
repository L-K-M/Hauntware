/// The OS-keystore side of the vault, shared by Séance, Poltergeist and
/// Klabautermann: the vault master key and the API-key entries, behind
/// one `MasterKeyManager` that each product constructs with its own entry
/// names, so no two products ever share a keystore entry.
///
/// Over `flutter_secure_storage` and `seance_protocol` only. Never
/// `seance_core`, `poltergeist_core` or `dartssh2`: Poltergeist consumes
/// this package and must not inherit the SSH stack. App lock integration,
/// product error copy and the sync credential bindings stay in each app
/// (docs/design/catalog-library.md section 9).
library;

export 'src/master_key_manager.dart';
