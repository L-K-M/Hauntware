/// Shared server surfaces for Séance, Poltergeist and Klabautermann, over
/// `seance_protocol` and `ghost_ui`. Never `seance_core`,
/// `poltergeist_core` or `dartssh2`: Poltergeist consumes this package and
/// must not inherit the SSH stack.
///
/// The server list's sectioning rules, the status-dot vocabulary and the
/// host-key, keyboard-interactive and credential prompts are here now; the
/// connection log view and test report land on this same edge in a later
/// stage of docs/design/ghost-servers-part1.md.
library;

export 'src/credential_dialog.dart';
export 'src/host_key_dialog.dart';
export 'src/keyboard_interactive_dialog.dart';
export 'src/server_grouping.dart';
export 'src/server_editor/strings.dart';
export 'src/server_status.dart';
