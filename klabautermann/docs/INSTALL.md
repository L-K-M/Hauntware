# Installing Klabautermann

Download Klabautermann only from this repository's
[Releases page](https://github.com/L-K-M/Hauntware/releases). Until v1 its
assets are named `klabautermann-preview-*` (the Debian package keeps its
`klabautermann_<version>` name): they are previews, built and checked like
the other products' clients but not yet signed off on every platform. The
desktop builds are unsigned (macOS: ad-hoc), so the first launch on each
platform takes one extra step, below. On Android you sideload the APK.

Klabautermann installs nothing on your servers. It connects over SSH
while it is open; what that covers, and what it does not, is in
[COVERAGE.md](COVERAGE.md).

## Verify your download first

Every release publishes `SHA256SUMS` beside its assets, and the release
notes carry the same checksums. Before bypassing any OS gate, confirm that
what you downloaded is what CI built:

```bash
# Linux (run in the download directory)
sha256sum -c SHA256SUMS --ignore-missing

# macOS: filter the file you downloaded out of SHA256SUMS, then check it
grep 'klabautermann-preview-macos-universal.zip$' SHA256SUMS > SHA256SUMS.mac
shasum -a 256 -c SHA256SUMS.mac   # expect: ...zip: OK

# Windows (PowerShell)
Get-FileHash .\klabautermann-preview-windows-x64.zip -Algorithm SHA256
# compare the printed hash with the release-notes line for that file
```

The checksums are computed by CI beside the artifacts, so they catch a
corrupted download or a foreign mirror. They cannot attest a compromised
release pipeline, and a matching checksum says nothing about who produced
the binary: the only origin assurance is that this repository's CI built
it from the pushed tag. An installer or "update" offered anywhere else is
not ours. Klabautermann never updates itself.

## macOS

`klabautermann-preview-macos-universal.zip`: unzip it, then move
`Klabautermann.app` to Applications (or anywhere you like).

The app is ad-hoc signed, so Gatekeeper blocks the first launch:

- right-click (or Control-click) `Klabautermann.app`, choose **Open** and
  confirm, **or**
- run `xattr -dr com.apple.quarantine /path/to/Klabautermann.app`.

macOS may ask for access to the keychain item that holds the app's vault
key. Allow it; "Always Allow" keeps it from asking again.

## Windows

`klabautermann-preview-windows-x64.zip`: extract it somewhere permanent
(the folder is the installation; there is no installer), then run
`klabautermann.exe` inside `klabautermann-preview-windows-x64\`.

The binary is unsigned, so SmartScreen shows "Windows protected your PC":
choose **More info**, then **Run anyway**.

## Linux

Four assets; pick one:

- `klabautermann_<version>-1_amd64.deb` (Debian, Ubuntu):
  `sudo apt install ./klabautermann_*_amd64.deb`. apt resolves the
  dependencies from the package.
- `klabautermann-preview-linux-x64.flatpak` (any distribution with
  Flatpak): `flatpak install klabautermann-preview-linux-x64.flatpak`. It
  pulls the GNOME runtime from Flathub on first install.
- `klabautermann-preview-linux-x64.AppImage` (any distribution):
  `chmod +x klabautermann-preview-linux-x64.AppImage`, then run it.
- `klabautermann-preview-linux-x64.tar.gz` (plain bundle): extract it and
  run the `klabautermann` binary inside.

Saving passwords and keys needs a Secret Service keyring: `libsecret-1`
plus a provider such as GNOME Keyring or KWallet. Without one the app
runs, but it refuses to store secrets rather than write them somewhere
weaker. The `.deb` declares the library; with the AppImage or the tarball,
install `libsecret-1-0` (Debian, Ubuntu) or `libsecret` (Fedora, Arch)
yourself. The Flatpak reaches the keyring through the Secret Service
portal.

The Flatpak sandbox reads only `~/.ssh/config`, not the rest of `~/.ssh`.
A server whose `IdentityFile` lies there connects through your SSH agent
(the sandbox may use it) or after you import the key into the app's vault
in the server editor; otherwise it fails with a sandbox-denied key error
rather than falling back to another key. A running sandbox keeps the
config it started with, so relaunch after editing `~/.ssh/config`.

## Android

`klabautermann-preview-android.apk` runs on Android 7.0 (API 24) or
later. There is no Play Store listing; you install the APK yourself:

1. Download the APK and check it against `SHA256SUMS` (on a computer, as
   above), then copy it to the phone.
2. Open the APK on the phone. Android asks you to allow installs from the
   app that opened it (your file manager or browser): allow it, then
   install. Or, with USB debugging on, run
   `adb install -r klabautermann-preview-android.apk` from the computer
   (`-r` replaces an installed copy and keeps its data).

A later release's APK installs over the current one and keeps your
servers and settings. Install it the same way: Klabautermann does not
download updates.

The APK is signed with a committed, deliberately public key. That is what
lets each release's APK upgrade an installed one in place; it also means
a matching signature proves nothing about origin, which is why the
checksum check above matters. If the key is ever replaced, existing
installs must be uninstalled first, and the release notes will say so.

A phone reads servers only while Klabautermann is in the foreground (see
[COVERAGE.md](COVERAGE.md#phones)).

## iOS: unsigned, not supported

Every release also attaches `klabautermann-preview-ios-unsigned.ipa`. It
is a build check of the codebase, not a supported build: it is unsigned
and installs on no device without a separate re-signing step (AltStore,
Sideloadly or an Xcode free account).

## Your servers

Klabautermann needs nothing on a server but SSH access and a POSIX shell.
It is built and tested against Debian, Ubuntu, the RHEL family, Fedora and
Arch with systemd, plus Alpine and BusyBox hosts with fewer features; on
the first connect it probes what the server offers and leaves out what it
lacks.

- It reads your servers as your login user. Actions that need root ask
  you to turn on admin mode with your sudo password (sudo, sudo-rs,
  NOPASSWD rules, passwordless doas and run0 work); the password is kept
  in memory only while admin mode lasts.
- New servers start observe-only: Klabautermann reads them and changes
  nothing until you turn on Allow actions in the server header's Safety
  menu.
- Every action shows its preview first, naming the commands it runs and
  every file it writes. When it writes something (a backup of a file you
  edited, its manifest, one line per action in the server's system log),
  the server header's Safety > Footprint lists it and removes what you no
  longer want.
- Docker is read through the engine's socket over SSH. Reaching a socket
  your account may not use takes admin mode, and the Docker tab warns that
  such access equals root on the host.

## Getting help

File issues at <https://github.com/L-K-M/Hauntware/issues>. The release
notes and [STATUS.md](STATUS.md) list what is known to be missing.
