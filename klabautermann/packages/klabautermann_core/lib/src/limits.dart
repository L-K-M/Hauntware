/// Small bounds the engine's readers and queries run under.
library;

/// The exit status a shell gives a command it cannot find.
const int kCommandNotFound = 127;

/// How many characters of a command's detail text an answer keeps; more
/// is cut rather than carried through the protocol.
const int kDetailLimit = 500;
