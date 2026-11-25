part of 'commands.dart';

/// [HostCommands.mounts]'s section markers: `findmnt`'s JSON, or
/// `/proc/self/mounts` where findmnt is missing or too old for `-J`, then
/// `/proc/swaps`.
const kMountsFindmntMarker = '== findmnt';
const kMountsProcMarker = '== proc';
const kMountsSwapsMarker = '== swaps';

/// The line [HostCommands.diskUsage] prints before what `du` said on
/// stderr, which `parseDiskUsage` reads for folders it could not read.
const kDiskUsageErrorsMarker = '== du errors';

/// The tools that export a whole filesystem for the explorer, in the
/// order it prefers them; the capability probe names each it finds.
enum DiskUsageExportTool { ncdu, gdu }

/// The most entries one [HostCommands.diskUsage] read lists, largest
/// first [E]: a folder of mail or cache files can hold far more than a
/// list is useful for.
const kDiskUsageEntries = 1000;
