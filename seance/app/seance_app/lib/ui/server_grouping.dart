// The server list's sectioning, shared with Poltergeist through
// ghost_servers since 2026-10-13 (docs/design/ghost-servers-part1.md,
// PR 2); Séance's section titles are the package's defaults. The export
// keeps this path, and exactly the names it declared, for the app.
export 'package:ghost_servers/ghost_servers.dart'
    show
        ServerGroupHeaderRow,
        ServerGroupSection,
        ServerListRow,
        ServerRow,
        ServerSectionRow,
        ServerSidebarSections,
        groupServers,
        hiddenByHeader,
        kPinnedKey,
        kPinnedLabel,
        kServersKey,
        kServersLabel,
        sectionsHoldingLive,
        serverListRows;
