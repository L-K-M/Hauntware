import 'package:dartssh2/dartssh2.dart';

/// The algorithm proposal every Séance and Poltergeist SSH client sends.
/// `poltergeist_bench` uses it too, so its measurements describe what the
/// apps negotiate.
///
/// The goal is that moving from dartssh2 3.0.2 to 4.1.0 keeps what servers
/// negotiate: key exchange and host key orders are 3.0.2's (minus what 3.1.0
/// removed), and any server that offers AES-128-CTR, which is every modern
/// one, gets it as before. The exceptions are deliberate: servers 3.0.2
/// could not reach (chacha20-poly1305 or AES-GCM only) now connect, a server
/// without AES-128-CTR gets the stronger cipher this list ranks first rather
/// than 3.0.2's AES-128-CBC, and servers that offer only what 3.1.0 removed
/// no longer connect. Tightening these defaults is a separate product
/// decision.
///
/// Key exchange and MACs are dartssh2 4.1.0's defaults. The two SHA-1 key
/// exchanges 4.0.0 dropped are appended as a last resort for old routers,
/// NAS boxes and embedded servers that offer nothing newer: RFC 4253 §7.1
/// picks the first client entry the server also offers, so they are only
/// reached when nothing above them is shared.
///
/// Host keys keep 3.0.2's order, with `ssh-rsa` between the SHA-2 RSA
/// signatures and ECDSA rather than last. A server that offers its RSA key
/// only as `ssh-rsa` (OpenSSH 5.7 to 7.1) plus an ECDSA key presented the
/// RSA key under 3.0.2; with `ssh-rsa` last it would present the ECDSA key,
/// which the pinned fingerprint does not match, and the user would get a
/// false "host key changed" warning. Servers that offer ed25519 or
/// `rsa-sha2-*` are unaffected.
///
/// Ciphers prefer AES-CTR, which 3.0.2 negotiated with every modern server.
/// dartssh2 3.1.0 moved AES-GCM to the front, but its AES-GCM is pure Dart
/// and far slower than its AES-CTR (a 32 MiB SFTP read from the fixture ran
/// at 13.7 MiB/s with this list against 0.72 MiB/s with 4.1.0's defaults),
/// enough to stall the isolate that decrypts. AES-CTR is also the safer choice against servers
/// without strict key exchange: Terrapin (CVE-2023-48795) targets
/// chacha20-poly1305 and CBC with encrypt-then-MAC. AES-GCM stays available
/// behind chacha20-poly1305, and the two CBC ciphers 4.0.0 dropped come
/// last, exposed to Terrapin too and kept only for servers that offer
/// nothing newer.
///
/// Nothing 3.1.0 removed as broken comes back: `diffie-hellman-group1-sha1`,
/// `hmac-md5` and the truncated `hmac-sha2-*-96` MACs stay off.
///
/// `ssh_algorithms_test.dart` pins every list by wire name and checks it
/// against `const SSHAlgorithms()`, so a re-pin that changes dartssh2's
/// defaults fails there and gets looked at rather than silently changing
/// the proposal.
///
/// Not exported from the barrel: the SSH clients in this package, in
/// Poltergeist's connection module and in its bench are the only consumers,
/// and neither app's UI should see dartssh2 types.
final SSHAlgorithms suiteSshAlgorithms = SSHAlgorithms(
  kex: List.unmodifiable([
    ...const SSHAlgorithms().kex,
    SSHKexType.dh14Sha1,
    SSHKexType.dhGexSha1,
  ]),
  hostkey: List.unmodifiable(const [
    SSHHostkeyType.ed25519,
    SSHHostkeyType.rsaSha512,
    SSHHostkeyType.rsaSha256,
    SSHHostkeyType.rsaSha1,
    SSHHostkeyType.ecdsa521,
    SSHHostkeyType.ecdsa384,
    SSHHostkeyType.ecdsa256,
  ]),
  cipher: List.unmodifiable(const [
    SSHCipherType.aes128ctr,
    SSHCipherType.aes256ctr,
    SSHCipherType.chacha20poly1305,
    SSHCipherType.aes256gcm,
    SSHCipherType.aes128gcm,
    SSHCipherType.aes256cbc,
    SSHCipherType.aes128cbc,
  ]),
  mac: List.unmodifiable(const SSHAlgorithms().mac),
);
