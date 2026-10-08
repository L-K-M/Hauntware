# Design: Séance credential recovery (CRED-05, remaining slices)

Status: proposal for owner approval. No code until approved.
Landed first: the credential-required state (#97): `resolveCredentials`
throws `CredentialMissingException` and the failed tab offers the server's
editor.

## Problem

A device's secrets live in `vault.json`, sealed with XChaCha20-Poly1305
under one 32-byte vault key (`VaultCrypto.seal`, `seance_protocol/lib/src/
crypto/vault.dart:173`). The key sits in the OS keystore
(`SecureMasterKey`). Losing the keystore or the device loses every
password and stored key that was not synced. A new device receives synced
configs whose secrets stayed local and, since #97, reports them as
missing, with no way to bring them over.

`RecoveryKey` (`seance_protocol/lib/src/crypto/recovery_key.dart`)
already encodes 32 bytes as a checksummed Crockford Base32 code
(`XXXX-XXXX-...`, 52 symbols plus 2 checksum symbols). The app does not
use it yet.

## Constraint that shapes the design

The vault key is not stable. Sync enrolment re-keys the vault to the
shared key derived from the account passphrase (`AppServices._rekeyVault`,
`app_services.dart:422`, journalled by `FileVaultStore.stageRekey`). A
recovery code that *is* the vault key (the Atuin model RecoveryKey's doc
cites) stops working at the next enrolment or passphrase change, and
leaking it hands over the live vault key itself.

## Proposal: a wrapped vault key

1. **Recovery key.** At enrolment the app generates a separate random
   32-byte recovery key and shows it once as a `RecoveryKey` code. It
   never touches disk in the clear.
2. **Wrap.** The app stores `wrappedVaultKey = seal(HKDF(recoveryKey,
   "seance/v1/recovery-wrap"), vaultKey)` beside the vault, with a key
   check `HMAC-SHA256(HKDF(recoveryKey, "seance/v1/recovery-check"),
   "seance/v1/recovery-check")`. Each re-key re-wraps the new vault key
   under the same recovery key, inside the existing re-key journal, so
   one code keeps working across enrolments.
3. **Export.** "Export secrets…" writes one file: a versioned header (format
   version, created-at, entry count, key check, `wrappedVaultKey`) and the
   vault's sealed entries as they are, followed by a MAC over header and
   entries under `HKDF(vaultKey, "seance/v1/export-mac")`. The file holds no
   plaintext and is useless without the code.
4. **Restore.** On a new device "Restore secrets…" takes the file and the
   code. It checks the code's checksum and the key check before decrypting
   anything, unwraps the vault key, verifies the file MAC, opens every
   entry (AEAD), and re-seals each under this device's vault key in a
   staging file that replaces `vault.json` atomically. A failure at any step
   leaves the existing vault untouched. Entries that already exist here are
   kept unless the user chooses to replace them.
5. **Enrolment prompt.** Saving the first secret on a device without a
   recovery key offers "Set up recovery" (show the code, ask the user to
   re-type one group to confirm it was copied). Declining is remembered and
   offered again from Settings.
6. **Inline prompt.** The credential-required tab gains "Enter password…"
   / "Choose key file…" / "Use SSH agent" without opening the full editor.
7. **App lock (optional).** A biometric or passcode gate before secrets are
   read, at the same boundary as the vault unlock. Separate PR, off by
   default.

## Decisions needed from you

- **A. Wrapped key (proposed) or code = vault key.** The wrapped key costs
  one extra file and a re-wrap step in the re-key journal; the alternative
  breaks on every enrolment.
- **B. One standing code (proposed) or a fresh code per export.** A fresh
  code per export needs no enrolment step but means a code for every file
  the user keeps.
- **C. Restore merge policy:** keep existing entries (proposed) or replace.
- **D. Scope of the first implementation PR:** slices 1-4 (wrap, export,
  restore), then 5 and 6, then 7 (proposed), or another order.
- **E. App lock:** build it, or leave it out of CRED-05.

## Test plan (from ANALYSIS.md's gate)

Two devices with and without credential opt-in; locked and missing keys;
export round trip; tamper rejection (flipped byte in header, entry, MAC;
truncated file; wrong code; code with one mistyped symbol); cancelled
recovery; interrupted import (kill between staging and swap leaves the old
vault); re-key after enrolment keeps the code working. The local SFTP
plaintext copies are explained separately from vault guarantees in the
docs.

## Size

Roughly 600-900 lines of Dart across `seance_core`/`seance_app` plus tests,
in three PRs (wrap + export/restore, enrolment + inline prompt, app lock).
