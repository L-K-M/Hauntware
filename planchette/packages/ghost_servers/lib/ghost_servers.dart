/// Shared server surfaces for Séance, Poltergeist and Klabautermann, over
/// `seance_protocol` and `ghost_ui`. Never `seance_core`,
/// `poltergeist_core` or `dartssh2`: Poltergeist consumes this package and
/// must not inherit the SSH stack.
///
/// The server list's sectioning rules, the status-dot vocabulary, the
/// host-key, keyboard-interactive and credential prompts, and the connection
/// log view and test report (docs/design/ghost-servers-part1.md).
library;

export 'src/connection_log_view.dart';
export 'src/connection_test_report.dart';
export 'src/credential_dialog.dart';
export 'src/host_key_dialog.dart';
export 'src/keyboard_interactive_dialog.dart';
export 'src/server_grouping.dart';
export 'src/server_editor/delegate.dart';
export 'src/server_editor/draft.dart';
export 'src/server_editor/server_editor.dart';
export 'src/server_editor/strings.dart';
export 'src/server_status.dart';
