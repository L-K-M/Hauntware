/// The host as an endpoint line shows it: a bare IPv6 address gains
/// brackets, so its colons cannot be read as the port separator
/// (`fe80::1` on port 22 would otherwise read `fe80::1:22`, a different
/// address). An already bracketed host is left as it is.
String endpointDisplayHost(String host) =>
    host.contains(':') && !(host.startsWith('[') && host.endsWith(']'))
    ? '[$host]'
    : host;
