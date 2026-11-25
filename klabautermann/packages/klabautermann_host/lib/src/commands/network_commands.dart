part of 'commands.dart';

/// The markers in [HostCommands.listeningPorts]' output: which tool
/// listed the sockets (`== ss`, `== netstat` or `== none`), then
/// `== cgroup <pid>` before each listed process's cgroups.
const kPortsToolMarker = '==';
const kPortsCgroupMarker = '== cgroup';

/// The markers before each part of [HostCommands.interfaces]' output:
/// the sysfs link files, the physical interfaces, the addresses, the TCP
/// socket states and `/proc/net/sockstat`.
const kNetLinksMarker = '== links';
const kNetPhysicalMarker = '== physical';
const kNetAddrMarker = '== addr';
const kNetTcpMarker = '== tcp';
const kNetSockstatMarker = '== sockstat';
