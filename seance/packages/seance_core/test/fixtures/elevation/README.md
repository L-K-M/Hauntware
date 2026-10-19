# Recorded elevation refusals

Each `.stderr` file is a refusal's full stderr, copied byte for byte from
Klabautermann's spike S3 case files
(`klabautermann/docs/evidence/s3/`, captured 2026-10-18):

| File | Case file | Call |
| --- | --- | --- |
| `sudo-1.9.16p2.password-required.stderr` | `debian-13-sudo-tty.json` | raw `sudo -n -l` |
| `sudo-1.9.16p2.wrong-password.stderr` | `debian-13-sudo-tty.json` | prelude, wrong password |
| `sudo-1.9.16p2.requiretty.stderr` | `debian-13-sudo-requiretty.json` | prelude, right password |
| `sudo-rs-0.2.13.password-required.stderr` | `ubuntu-2604-sudo-rs.json` | raw `sudo -n -l` |
| `sudo-rs-0.2.13.prelude-password-required.stderr` | `ubuntu-2604-sudo-rs-timeout-0.json` | prelude, right password, before the rung-4 retry |
| `sudo-rs-0.2.13.wrong-password.stderr` | `ubuntu-2604-sudo-rs.json` | prelude, wrong password |
| `opendoas-6.8.2.authentication-required.stderr` | `alpine-322-doas-password.json` | raw `doas -n true` |
| `opendoas-6.8.2.tty-required.stderr` | `alpine-322-doas-password.json` | raw `doas true`, password on a pipe |

`elevation_test.dart` classifies each one. When a later capture changes a
text, copy the new bytes here and keep the old file if older releases
still print it.
