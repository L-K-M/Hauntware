const String _leftToRightIsolate = '\u2066';
const String _popDirectionalIsolate = '\u2069';

/// Keeps a displayed logical path from reordering surrounding UI text.
String isolatePathForDisplay(String path) =>
    '$_leftToRightIsolate$path$_popDirectionalIsolate';
