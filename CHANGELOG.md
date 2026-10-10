# Changelog

## Unreleased

### Changed

- Séance and Poltergeist use dartssh2 4.1.0 instead of 3.0.2. Servers
  that offer only chacha20-poly1305 connect, strict key exchange is
  negotiated where a server offers it, a host key that changes during a
  rekey ends the connection, and Android handshake timeouts and stalled
  channels are fixed. Other servers negotiate the same algorithms as
  before, including those that offer only SHA-1 key exchange, `ssh-rsa`
  host keys or AES-CBC ciphers. Servers that offer only
  `diffie-hellman-group1-sha1`, `hmac-md5` or truncated `hmac-sha2-*-96`
  MACs no longer connect. Each product's changelog has the details.

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
