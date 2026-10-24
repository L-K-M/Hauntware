import 'package:ghost_ui/ghost_ui.dart' show ColorPickerStrings;

/// The server editor's words, as one bag (docs/design/ghost-servers-part2.md,
/// section 4). The defaults are Séance's literals, which match Poltergeist's
/// English catalog word for word; the start folder's members, which Séance
/// lacks, default to Poltergeist's. A host with localized copy passes its own.
///
/// Not here: the transfer limit and jump route words, which stay with
/// Poltergeist's own sections, the colour names, which are vocabulary in
/// both apps, and the mark picker's words, which join when the appearance
/// section moves with `ghost_marks` (F5a-2a).
final class GhostServerEditorStrings {
  const GhostServerEditorStrings({
    this.addTitle = 'Add server',
    this.editTitle = 'Edit server',
    this.label = 'Label',
    this.host = 'Host',
    this.port = 'Port',
    this.username = 'Username',
    this.authentication = 'Authentication',
    this.authAgent = 'ssh-agent',
    this.authPassword = 'Password',
    this.authPrivateKey = 'Private key',
    this.agentInfo = 'Keys are provided by your ssh-agent; nothing is stored.',
    this.passwordLabel = 'Password',
    this.referenceKeyTitle = 'Reference a key file on disk',
    this.referenceKeySubtitle = "Don't store the key — read it at connect",
    this.identityFilePath = 'Identity file path',
    this.identityFileHint = '~/.ssh/id_ed25519',
    this.browse = 'Browse…',
    this.privateKeyPem = 'Private key (PEM/OpenSSH)',
    this.keyPassphrase = 'Key passphrase (optional)',
    this.startDirectory = 'Start folder (optional)',
    this.startDirectoryHint = 'e.g. ~/sites or /var/www',
    this.startDirectoryNote =
        'Opens when you connect to this server. A relative path starts in '
        'your home folder. Blank opens your home folder.',
    this.startDirectoryInvalid =
        'Use an absolute path such as /var/www, or one in your own home such '
        'as ~/sites.',
    this.loginScript = 'Login script (optional)',
    this.loginScriptHint =
        'e.g. cd ~/work && tmux attach -t work || tmux new -s work',
    this.loginScriptNote =
        'Runs as if typed at the prompt right after connecting. Its text and '
        'output land in scrollback — keep secrets out. Blank for none.',
    this.appearance = 'Appearance',
    this.group = 'Group',
    this.groupHint = 'Production, Home lab, … — blank for none',
    this.colour = 'Colour',
    this.mark = 'Mark',
    this.chooseMark = 'Choose…',
    this.defaultMarkTooltip = 'Use the default mark',
    this.customColour = 'Custom colour…',
    this.syncSecretTitle = 'Allow this credential to sync',
    this.syncSecretExcluded =
        'Not used while this server is excluded from sync.',
    this.syncSecretSubtitle =
        'End-to-end encrypted. Also needs sync set up with "Sync saved '
        'passwords & keys" enabled.',
    this.excludeTitle = 'Exclude from sync',
    this.excludeOnSubtitle =
        'Kept on this device only. A copy that synced earlier is removed '
        'from the sync server and from your other devices.',
    this.excludeOffSubtitle =
        'Keep this server on this device only — never upload it.',
    this.excludeConfirmTitle = 'Exclude from sync?',
    this.excludeConfirmBody =
        'If this server synced earlier, it is removed from the sync server '
        'and from your other devices, along with any credential that synced '
        'with it. This device keeps its copy.',
    this.excludeConfirmCancel = 'Cancel',
    this.excludeConfirmAction = 'Exclude',
    this.test = 'Test connection',
    this.testing = 'Testing…',
    this.testingSemantic = 'Testing connection',
    this.testFailedSummary = 'Could not test the connection.',
    this.testDisclaimer =
        'Testing authenticates without opening a shell or running the login '
        'script. A host key you approve here is trusted for the test only — '
        'the first real connection asks again.',
    this.cancel = 'Cancel',
    this.save = 'Save',
    this.required = 'Required',
    this.portRange = '1–65535',
    this.saveFailed = _saveFailed,
    this.customColourValue = _customColourValue,
    this.colorPickerStrings = const ColorPickerStrings(),
  });

  /// The titles over a new and an existing server.
  final String addTitle;
  final String editTitle;

  /// The connection fields.
  final String label;
  final String host;
  final String port;
  final String username;

  /// The sign-in method menu and its three choices.
  final String authentication;
  final String authAgent;
  final String authPassword;
  final String authPrivateKey;

  /// The line under the agent choice.
  final String agentInfo;

  /// The password field.
  final String passwordLabel;

  /// The switch between a key file on disk and a pasted key.
  final String referenceKeyTitle;
  final String referenceKeySubtitle;

  /// The key file field, its hint and its picker button.
  final String identityFilePath;
  final String identityFileHint;
  final String browse;

  /// The pasted key and its passphrase.
  final String privateKeyPem;
  final String keyPassphrase;

  /// The start folder field, its hint, its note and its error. Séance has no start folder, so these are Poltergeist's words.
  final String startDirectory;
  final String startDirectoryHint;
  final String startDirectoryNote;
  final String startDirectoryInvalid;

  /// The login script field, its hint and its note.
  final String loginScript;
  final String loginScriptHint;
  final String loginScriptNote;

  /// The appearance section: its heading, the group field, the colour row and the mark row.
  final String appearance;
  final String group;
  final String groupHint;
  final String colour;
  final String mark;
  final String chooseMark;
  final String defaultMarkTooltip;

  /// The custom colour swatch's tooltip before a colour is chosen.
  final String customColour;

  /// The credential sync switch, and its subtitle while the server is excluded and otherwise.
  final String syncSecretTitle;
  final String syncSecretExcluded;
  final String syncSecretSubtitle;

  /// The exclude-from-sync switch and its subtitles while on and off.
  final String excludeTitle;
  final String excludeOnSubtitle;
  final String excludeOffSubtitle;

  /// The confirmation before excluding a server that may have synced.
  final String excludeConfirmTitle;
  final String excludeConfirmBody;
  final String excludeConfirmCancel;
  final String excludeConfirmAction;

  /// The test button, its label and spoken label while a test runs, and the summary of a test that threw.
  final String test;
  final String testing;
  final String testingSemantic;
  final String testFailedSummary;

  /// The note under the buttons.
  final String testDisclaimer;

  /// The dialog's buttons.
  final String cancel;
  final String save;

  /// The validation errors of a blank required field and a port out of range.
  final String required;
  final String portRange;

  /// The toast of a save that threw, from the error's text.
  final String Function(String error) saveFailed;

  /// The custom colour swatch's tooltip, from the chosen colour's hex.
  final String Function(String hex) customColourValue;

  /// The custom colour picker's words.
  final ColorPickerStrings colorPickerStrings;
}

String _saveFailed(String error) => 'Could not save: $error';

String _customColourValue(String hex) => 'Custom colour ($hex)';
