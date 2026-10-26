#!/usr/bin/env python3
"""Fetch the license texts of the third-party code inside Dart's AOT runtime.

`dart compile exe` copies the SDK's precompiled runtime (dartaotruntime)
into every executable. Besides the Dart SDK itself (BSD-3-Clause, LICENSE in
the SDK root) that runtime statically links BoringSSL, ICU, zlib, LLVM's
libc++/libc++abi/libunwind, Perfetto and double-conversion. The SDK archive
ships none of their texts, so this script downloads each one at the exact
revision the SDK was built from: it reads the SDK's `revision` file, reads
the pinned dependency revisions from that commit's DEPS file, and fetches
each LICENSE from the upstream repository at that revision.

It writes <out>/<Component>-LICENSE.txt files and <out>/components.json,
which `go-dart-notices.py dart --runtime-licenses <out>` reads. Commit the
directory (deterministic builds, no network during builds) and refresh it
whenever the SDK version changes; the generator fails unless the SDK's
version and revision match the ones recorded here.

  dart-runtime-licenses.py --out licenses/dart-runtime            # SDK of `dart` on PATH
  dart-runtime-licenses.py --sdk "$DART_SDK" --out /tmp/dart-runtime  # official dart image

The component list was checked against dartaotruntime 3.13.7 (linux-x64):
its strings name boringssl, perfetto, ICU 77, libunwind, libc++abi and
zlib's inflate messages. The list is the union over platforms; a component
a platform links dynamically instead is harmless to list. Each fetched text
must contain the expected phrases, so a relicensed upstream fails loudly.

Python 3.8+ standard library only; needs network access to GitHub and
googlesource.com.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

DART_RAW = "https://raw.githubusercontent.com/dart-lang/sdk/{sdk}/{path}"
GOOGLESOURCE = "https://{host}/{repo}/+/{rev}/{path}?format=TEXT"

# name, DEPS variable (None: inside the SDK repository), where the text lives,
# expected SPDX expression, phrases the text must contain, note.
COMPONENTS = [
    ("BoringSSL", "boringssl_rev",
     ("boringssl.googlesource.com", "boringssl", "LICENSE"),
     "Apache-2.0", ["Apache License", "Version 2.0"], None),
    ("ICU", "icu_rev",
     ("chromium.googlesource.com", "chromium/deps/icu", "LICENSE"),
     "Unicode-3.0 AND ICU", ["UNICODE LICENSE V3", "ICU License"],
     "The text also lists the licenses of ICU's data files and build scripts."),
    ("zlib", "zlib_rev",
     ("chromium.googlesource.com", "chromium/src/third_party/zlib", "LICENSE"),
     "Zlib", ["Jean-loup Gailly and Mark Adler", "altered source versions must be plainly marked"],
     "Chromium's copy of zlib."),
    ("LLVM libc++, libc++abi and libunwind", "libcxx_rev",
     ("llvm.googlesource.com", "llvm-project/libcxx", "LICENSE.TXT"),
     "Apache-2.0 WITH LLVM-exception AND NCSA AND MIT",
     ["Apache License v2.0 with LLVM Exceptions", "University of Illinois/NCSA"],
     "libc++abi and libunwind are part of the LLVM project under the same license."),
    ("Perfetto", "perfetto_rev",
     ("chromium.googlesource.com", "external/github.com/google/perfetto", "LICENSE"),
     "Apache-2.0", ["Apache License", "Version 2.0"], "Timeline tracing support."),
    ("double-conversion", None, "third_party/double-conversion/LICENSE",
     "BSD-3-Clause", ["Redistribution and use in source and binary forms", "Neither the name"], None),
]


def find_sdk():
    """SDK root of the `dart` on PATH (Flutter's wrapper points into bin/cache/dart-sdk)."""
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        for name in ("dart", "dart.exe", "dart.bat"):
            executable = Path(directory) / name
            if executable.is_file():
                root = executable.resolve().parent.parent
                for candidate in (root / "bin" / "cache" / "dart-sdk", root):
                    if ((candidate / "version").is_file() and (candidate / "revision").is_file()
                            and (candidate / "lib" / "_internal").is_dir()):
                        return candidate
    sys.exit("error: Dart SDK not found on PATH; pass --sdk")


def fetch(url):
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            return response.read()
    except OSError as error:
        sys.exit(f"error: cannot fetch {url}: {error}")


def clean(data):
    text = data.decode("utf-8").replace("\r\n", "\n")
    return text.strip("\n") + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--sdk", type=Path, help="Dart SDK root (has version and revision files)")
    parser.add_argument("--version", help="SDK version, instead of --sdk")
    parser.add_argument("--revision", help="dart-lang/sdk commit, instead of --sdk")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if bool(args.version) != bool(args.revision):
        parser.error("--version and --revision go together")
    if args.version:
        version, revision = args.version, args.revision
    else:
        sdk = args.sdk or find_sdk()
        version = (sdk / "version").read_text(encoding="utf-8").strip()
        revision = (sdk / "revision").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        sys.exit(f"error: unexpected SDK revision {revision!r}")

    deps = fetch(DART_RAW.format(sdk=revision, path="DEPS")).decode("utf-8")
    pins = dict(re.findall(r'"(\w+_rev)"\s*:\s*"([0-9a-f]{40})"', deps))
    args.out.mkdir(parents=True, exist_ok=True)
    components = []
    for name, variable, where, expression, phrases, note in COMPONENTS:
        if variable is None:
            rev = revision
            url = DART_RAW.format(sdk=revision, path=where)
            source = f"https://github.com/dart-lang/sdk/tree/{revision}/{where.rsplit('/', 1)[0]}"
            text = clean(fetch(url))
        else:
            if variable not in pins:
                sys.exit(f"error: {variable} not in DEPS at {revision}; update COMPONENTS")
            rev = pins[variable]
            host, repo, path = where
            url = GOOGLESOURCE.format(host=host, repo=repo, rev=rev, path=path)
            source = f"https://{host}/{repo}/+/{rev}"
            text = clean(base64.b64decode(fetch(url)))
        missing = [phrase for phrase in phrases if phrase.lower() not in text.lower()]
        if missing:
            sys.exit(f"error: {name} license text at {rev} lacks {missing}; review it and update "
                     f"COMPONENTS (expected {expression})")
        filename = re.sub(r"[^A-Za-z0-9.+-]+", "-", name).strip("-") + "-LICENSE.txt"
        (args.out / filename).write_text(text, encoding="utf-8")
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        print(f"{filename}  {rev}  sha256 {digest}")
        entry = {"name": name, "version": rev, "license": expression, "source_url": source,
                 "files": [filename]}
        if note:
            entry["note"] = note
        components.append(entry)
    manifest = {"sdk_version": version, "sdk_revision": revision, "components": components}
    (args.out / "components.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out / 'components.json'} for Dart {version}")


if __name__ == "__main__":
    main()
