/// The backoff for reopening a dropped Docker stream: the container log
/// follow and the events watch both read again after 1 s, 2 s, ... up to
/// the ceiling. The router's own endpoint ladder keeps a different,
/// slower private backoff.
library;

/// The first delay before a dropped Docker stream is opened again.
const Duration kDockerRetryBase = Duration(seconds: 1);

/// The ceiling a Docker stream's reopen delay grows to.
const Duration kDockerRetryCap = Duration(seconds: 30);
