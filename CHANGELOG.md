# Changelog

## Unreleased

### Changed

- Séance and Poltergeist use dartssh2 4.1.0 instead of 3.0.2. Servers
  that offer only chacha20-poly1305 connect, strict key exchange is
  negotiated where a server offers it, a host key that changes during a
  rekey ends the connection, and Android handshake timeouts and stalled
  channels are fixed. Other servers keep the cipher and host key they
  negotiated before, so transfer speed and pinned host keys are
  unchanged, and servers that offer only SHA-1 key exchange, `ssh-rsa`
  host keys or AES-CBC ciphers still connect. Servers that offer only
  `diffie-hellman-group1-sha1`, `hmac-md5` or truncated `hmac-sha2-*-96`
  MACs no longer connect. Each product's changelog has the details.
- Séance's terminal text size, font, ligatures and colour choice moved
  from Settings ▸ General to Settings ▸ Appearance. Its preview there now
  draws in the terminal's font instead of the code font.

### Added

- The font catalog now has 20 families, including Cascadia Code, Victor
  Mono, Lilex, 0xProto and all five Monaspace faces. A searchable picker
  previews code, ambiguous characters and emphasis before applying a
  font. Ligatures are on by default and can be disabled, including the
  font-specific sets used by Monaspace, Geist Mono and Intel One Mono.
  All fonts work offline and ship with their OFL notices.
- Séance and Poltergeist on Android update themselves when you ask.
  When a newer release is out, Séance's update banner and Poltergeist's
  Alerts tab offer Update with the download size. The app downloads
  that release's APK, discards it unless its size and SHA-256 match what
  the release lists, and opens Android's installer, which asks you to
  allow installs from the app the first time and then to confirm. The
  launch check is unchanged, nothing downloads until you choose Update,
  and desktop and iOS builds still link to the release page.
- Planchette, Séance and Poltergeist let you choose the built-in
  editor's font and turn its ligatures off. Each app keeps the choice on
  the device, like the editor's text size.
- Every app ships open-source monospace fonts, including Iosevka Term,
  JetBrains Mono, Fira Code and Maple Mono, all with ligatures such as
  `->` and `!=`. Code and editors in Planchette, Séance and Poltergeist
  draw in JetBrains Mono on every platform, where they used to fall back
  to Menlo, Cascadia Mono or DejaVu Sans Mono unless JetBrains Mono was
  installed. Planchette's settings-file `fontFamily` and Séance's
  terminal font accept the bundled families by name. The fonts are under the
  SIL Open Font License; each app's licence notices include it.
- Klabautermann, the fourth product: an agentless manager for servers
  and Docker over SSH, still in development. CI builds its Android, iOS,
  Linux, macOS and Windows clients on every pull request and launches
  the desktop ones, and `scripts/build.sh` builds it with the other
  products. Suite releases do not ship it until its preview milestone;
  its [changelog](klabautermann/CHANGELOG.md) tracks the work so far.

## 1.9.0 (2026-10-04)

First Hauntware suite release. Product changes since the last standalone
releases are listed in each product's changelog.

### Changed

- Planchette, Séance and Poltergeist share one repository, one version and
  one release. The standalone repositories are archived; their final
  releases point here.
- Séance and Poltergeist use `ch.lkmc.*` application IDs. Séance 0.9.2,
  Poltergeist 1.0.1 and earlier used `com.lkm.*`: suite builds install as
  new apps beside them and start without their data.
- The sync-server image stays `ghcr.io/l-k-m/seance`. Deployments built
  from a standalone Séance clone move to a Hauntware clone; see the
  [sync server README](seance/packages/seance_sync_server/README.md).

### Added

- Full Planchette, Séance and Poltergeist histories, with historical
  branch/ref and byte-exact tag metadata.
- Local shared dependencies and synchronized package/app versions.
- Coordinated tests, 13 client builds and a single gated suite release.

### Included source work

- Planchette #133: recovered editor, navigation and native-drop fixes.
- Séance #172/#44/#45: atomic host-key writes, opt-in local shells and
  container/vault preservation when a sandboxed macOS build with the same
  bundle ID leaves the sandbox.
- Poltergeist #252: guarded trash purge and interrupted-restore recovery.
