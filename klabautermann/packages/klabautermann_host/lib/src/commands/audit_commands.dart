part of 'commands.dart';

/// The longest each part of [HostCommands.auditLine] may be, in
/// characters.
const int kAuditLinePartMax = 200;

/// C0 and C1 controls, DEL and the Unicode line and paragraph
/// separators, which a syslog line must not carry: NEL and the separators
/// break lines in some viewers, and C1's CSI starts a terminal sequence.
final _controlCharacters = RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]');
