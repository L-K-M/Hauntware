# ghost_fonts

The 20 monospace families every Ghost app bundles, available offline.
`BundledMonoFont` names them; `ghostMonoFontFamilies` is the stack code text
falls back through. Apps register each family as
`packages/ghost_fonts/<family>` from their font manifest; tests call
`loadBundledMonoFonts()` from `package:ghost_fonts/testing.dart`.

| Family | Styles | Programming ligatures |
| --- | --- | --- |
| Iosevka Term (terminal default) | regular, bold, italic, bold italic | `calt` |
| JetBrains Mono (editor default) | regular, bold, italic, bold italic | `calt` |
| Fira Code | regular, bold | `calt` |
| Maple Mono | regular, bold, italic, bold italic | `calt` |
| Cascadia Code | regular, bold, italic, bold italic | `calt` |
| Victor Mono | regular, bold, italic, bold italic | `calt` |
| Lilex | regular, bold, italic, bold italic | `calt` |
| 0xProto | regular, bold, italic | `calt` |
| Monaspace Neon, Argon, Xenon, Radon, Krypton | each: regular, bold, italic, bold italic | `ss01`–`ss10`, `liga` |
| Martian Mono | regular, bold | `calt` |
| Geist Mono | regular, bold, italic, bold italic | `ss11` |
| Intel One Mono | regular, bold, italic, bold italic | `ss01` |
| Fragment Mono | regular, italic | `calt` |
| Google Sans Code | variable weight, upright and italic | none |
| Commit Mono | regular, bold, italic, bold italic | none |
| Departure Mono | regular | none |

The engine synthesizes styles absent upstream. Google Sans Code uses its
unmodified variable faces, with `MONO` at its default of 1. All fonts together
occupy about 21 MiB before application compression, about 16 MiB more than the
original four.

`showMonoFontPicker` shares searchable, font-rendered rows and a larger preview
with code, ambiguous glyphs and emphasis. Desktop uses two panes; narrow screens
stack them in a scrollable view. A host may supply its installed-font source and
terminal-specific preview. Nothing changes until confirmation.

Ligatures default to on and remain switchable. `MonoLigatures.featuresFor`
also controls fonts whose coding ligatures require stylistic sets; disabling
them turns those sets off. Fonts without coding ligatures say so in the picker.
Editors and terminals use the same feature policy. Rendering tests check real
font metrics and glyph changes, not just feature flags.

## Licences

The fonts are under the SIL Open Font License 1.1; the package code is public
domain (Unlicense). `LICENSE` holds every
text in the chunk format Flutter's build copies into each app's NOTICES, and
a test checks there is one per family. The suite licence gate
(`tool/license_gate`) covers Séance's component only, so it does not see
these files.

Cascadia Code reserves “Cascadia Code”; Intel One Mono reserves “Intel”;
Monaspace reserves “Monaspace” and its five subfamily names. Their shipped files
are unmodified. The other additional families declare no reserved names.
Commit Mono and Departure Mono's **font** licenses are OFL, regardless of the
licenses used for code in their repositories. Codelia is commercial and is not
included.

## Sources

Unmodified release files, except Iosevka Term:

| Family | Release | Archive (SHA-256) |
| --- | --- | --- |
| Iosevka Term | [be5invis/Iosevka v34.9.0](https://github.com/be5invis/Iosevka/releases/tag/v34.9.0) | `PkgTTF-Unhinted-IosevkaTerm-34.9.0.zip` (`b11472aab68b01d5936758962af8da5902ebbb7f8311303236f5e1023a4bee45`) |
| JetBrains Mono | [JetBrains/JetBrainsMono v2.304](https://github.com/JetBrains/JetBrainsMono/releases/tag/v2.304) | `JetBrainsMono-2.304.zip` (`6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf`), `fonts/ttf/` |
| Fira Code | [tonsky/FiraCode 6.2](https://github.com/tonsky/FiraCode/releases/tag/6.2) | `Fira_Code_v6.2.zip` (`0949915ba8eb24d89fd93d10a7ff623f42830d7c5ffc3ecbf960e4ecad3e3e79`), `ttf/` |
| Maple Mono | [subframe7536/maple-font v7.9](https://github.com/subframe7536/maple-font/releases/tag/v7.9) | `MapleMono-TTF.zip` (`3a35f8f0669bef3dded9df208cc4526a6f7573210e134816e9084a8981271d75`) |

The additional releases, exact archive members, source/license SHA-256 and
shipped-file SHA-256 are pinned in [`tool/font_releases.json`](tool/font_releases.json):

| Families | Release |
| --- | --- |
| Cascadia Code | [microsoft/cascadia-code v2407.24](https://github.com/microsoft/cascadia-code/releases/tag/v2407.24) |
| Victor Mono | [rubjo/victor-mono v1.5.6](https://github.com/rubjo/victor-mono/releases/tag/v1.5.6), nested `public/VictorMonoAll.zip` |
| Lilex | [mishamyrt/Lilex 2.630](https://github.com/mishamyrt/Lilex/releases/tag/2.630) |
| 0xProto | [0xType/0xProto 2.502](https://github.com/0xType/0xProto/releases/tag/2.502) |
| Monaspace (five families) | [githubnext/monaspace v1.400](https://github.com/githubnext/monaspace/releases/tag/v1.400), static OTFs |
| Martian Mono | [evilmartians/mono v1.1.0](https://github.com/evilmartians/mono/releases/tag/v1.1.0), standard-width TTFs |
| Geist Mono | [vercel/geist-font v1.8.1](https://github.com/vercel/geist-font/releases/tag/v1.8.1) |
| Intel One Mono | [intel/intel-one-mono V1.4.0](https://github.com/intel/intel-one-mono/releases/tag/V1.4.0) |
| Fragment Mono | [weiweihuanghuang/fragment-mono 1.21](https://github.com/weiweihuanghuang/fragment-mono/releases/tag/1.21) |
| Google Sans Code | [googlefonts/googlesans-code v7.001](https://github.com/googlefonts/googlesans-code/releases/tag/v7.001) |
| Commit Mono | [eigilnikolajsen/commit-mono v1.143](https://github.com/eigilnikolajsen/commit-mono/releases/tag/v1.143), hinted TTFs |
| Departure Mono | [rektdeckard/departure-mono v1.500](https://github.com/rektdeckard/departure-mono/releases/tag/v1.500) |

Google Sans Code's asset filenames omit brackets for Flutter's asset loader;
the bytes and internal family names are unchanged. Commit Mono's license chunk
also retains the copyright from its fonts' name table.

`python3 tool/import_font_releases.py --check` verifies these files offline.
Without `--check`, it restores the pinned files and their LICENSE chunks from
upstream, checking digests before writing. No font toolchain is needed.

Iosevka's full character set is about 8.4 MB per style. `tool/subset_iosevka.sh`
keeps the scripts, symbols, box drawing, braille and powerline characters a
terminal draws, and the default ligatures, and drops the character variants
nothing selects: about 480 KB per style. Characters it leaves out fall back
to the next family in the stack. The script verifies the archive checksum
and produces byte-identical files with fonttools 4.67.0.

## Shipped files (SHA-256)

```
41f6554e845e2f5b70adad3950122334b866aac436793b7742ade600067701be  fonts/FiraCode/FiraCode-Bold.ttf
5992ab9640e2df491b2f609467b1de60e8bc39b2c28db184342a0592d98f6117  fonts/FiraCode/FiraCode-Regular.ttf
fb2b2cf52292bd23e70164a4c175b9ac8cd78c6047eb65684cd4ed9e4bb96de7  fonts/IosevkaTerm/IosevkaTerm-Bold.ttf
a764b281a3cb3a5c0aab7eb8641bc44d3ad2b013ddf0b8cddea074aa84053191  fonts/IosevkaTerm/IosevkaTerm-BoldItalic.ttf
54a9c2436533e310fde9e64622ea700f4731ddad418e8d3d4e4395be02de0e76  fonts/IosevkaTerm/IosevkaTerm-Italic.ttf
9c11c76757268986effdcbcfd83cc944d3dd10bffa7d58f44fe5357f9c243bed  fonts/IosevkaTerm/IosevkaTerm-Regular.ttf
5590990c82e097397517f275f430af4546e1c45cff408bde4255dad142479dcb  fonts/JetBrainsMono/JetBrainsMono-Bold.ttf
4039d5ce0ed225bf9c8b2c8c6436290ae2f356b7e90d70fa666227238324aa3b  fonts/JetBrainsMono/JetBrainsMono-BoldItalic.ttf
9d0a1f7a708e6af183f1193b7e81d40da294f5c67682c085d8401c60aac8ded4  fonts/JetBrainsMono/JetBrainsMono-Italic.ttf
a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f  fonts/JetBrainsMono/JetBrainsMono-Regular.ttf
e0623db6219886ce8906f440b9668acc7fab96b94e4036ac7a27809cd4bb72d7  fonts/MapleMono/MapleMono-Bold.ttf
c9d6a8f203c86409aa63eb2b5716bd854819e481a8bdbe0bba1f7a476e59080f  fonts/MapleMono/MapleMono-BoldItalic.ttf
fde2a23a7062923761ac0e3c718718c181bdb9865325430175819eb55a495e90  fonts/MapleMono/MapleMono-Italic.ttf
369583f0b555f33bdb6fdbcc2a6840a7a61a1d72c008a57a665baa36d7d5adf6  fonts/MapleMono/MapleMono-Regular.ttf
```

Check with `sha256sum --check` after replacing a file, and update both tables.
