#!/usr/bin/env python3
"""Provide the license texts of the third-party code inside Dart's AOT runtime.

`dart compile exe` copies the SDK's precompiled runtime (dartaotruntime)
into every executable. Besides the Dart SDK itself (BSD-3-Clause, LICENSE in
the SDK root) that runtime statically links BoringSSL, ICU, zlib, LLVM's
libc++/libc++abi/libunwind, Perfetto and double-conversion. The SDK archive
ships none of their texts, so each one is taken at the exact revision the
SDK was built from: the SDK's `revision` file names a dart-lang/sdk commit,
that commit's DEPS file pins the dependency revisions, and each LICENSE is
read from the upstream repository at its pinned revision.

The texts are vendored in dart-runtime/ beside this script (cache.json
records each SDK's pins and each text's component, revision, source URL and
sha256), so builds of a recorded SDK need no network. An SDK or revision the
cache lacks is fetched live (DEPS and double-conversion from GitHub, the
others from googlesource.com) with a warning to refresh the cache; --offline
turns that into an error. Refresh deliberately, review the diff and commit:

  dart-runtime-licenses.py --refresh                     # SDK of `dart` on PATH
  dart-runtime-licenses.py --refresh --version 3.14.0 --revision <sha>

It writes <out>/<Component>-LICENSE.txt files and <out>/components.json,
which `go-dart-notices.py dart --runtime-licenses <out>` reads; that
generator fails unless the SDK's version and revision match the ones
recorded there. Output is the same whether a text came from the cache or the
network.

  dart-runtime-licenses.py --out /tmp/dart-runtime                 # SDK of `dart` on PATH
  dart-runtime-licenses.py --sdk "$DART_SDK" --out /tmp/dart-runtime  # official dart image

The component list was checked against dartaotruntime 3.13.7 (linux-x64):
its strings name boringssl, perfetto, ICU 77, libunwind, libc++abi and
zlib's inflate messages. The list is the union over platforms; a component
a platform links dynamically instead is harmless to list. Each text must
contain the expected phrases, so a relicensed upstream fails loudly.

Python 3.8+ standard library only.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DART_RAW = "https://raw.githubusercontent.com/dart-lang/sdk/{sdk}/{path}"
GOOGLESOURCE = "https://{host}/{repo}/+/{rev}/{path}?format=TEXT"
CACHE = Path(__file__).resolve().parent / "dart-runtime"
RETRY_DELAYS = (5, 20)  # seconds before the second and third attempt

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
    """GET url; transient failures (5xx, timeouts, resets) are retried."""
    for delay in RETRY_DELAYS + (None,):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code < 500 or delay is None:
                sys.exit(f"error: cannot fetch {url}: {error}")
            reason = error
        except OSError as error:
            if delay is None:
                sys.exit(f"error: cannot fetch {url}: {error}")
            reason = error
        print(f"warning: {url}: {reason}; retrying in {delay} s", file=sys.stderr)
        time.sleep(delay)


def clean(data):
    text = data.decode("utf-8").replace("\r\n", "\n")
    return text.strip("\n") + "\n"


def slug(name):
    return re.sub(r"[^A-Za-z0-9.+-]+", "-", name).strip("-")


def load_cache():
    path = CACHE / "cache.json"
    if not path.is_file():
        return {"sdks": {}, "texts": []}
    return json.loads(path.read_text(encoding="utf-8"))


def save_cache(cache):
    cache["texts"].sort(key=lambda item: (item["component"], item["revision"]))
    cache["sdks"] = dict(sorted(cache["sdks"].items(), key=lambda item: item[1]["version"]))
    (CACHE / "cache.json").write_text(json.dumps(cache, indent=2) + "\n", encoding="utf-8")


def cached_text(cache, name, rev):
    """The vendored text of component name at rev, or None."""
    for item in cache["texts"]:
        if item["component"] == name and item["revision"] == rev:
            path = CACHE / item["file"]
            data = path.read_bytes() if path.is_file() else b""
            if hashlib.sha256(data).hexdigest() != item["sha256"]:
                sys.exit(f"error: {path} does not match its sha256 in cache.json; restore it "
                         f"or refresh with --refresh")
            return data.decode("utf-8")
    return None


def cache_text(cache, name, rev, url, text):
    data = text.encode("utf-8")
    digest = hashlib.sha256(data).hexdigest()
    filename = f"{slug(name)}-{digest[:12]}.txt"
    (CACHE / filename).write_bytes(data)
    cache["texts"] = [item for item in cache["texts"]
                      if not (item["component"] == name and item["revision"] == rev)]
    cache["texts"].append({"component": name, "revision": rev, "url": url, "sha256": digest,
                           "file": filename})


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--sdk", type=Path, help="Dart SDK root (has version and revision files)")
    parser.add_argument("--version", help="SDK version, instead of --sdk")
    parser.add_argument("--revision", help="dart-lang/sdk commit, instead of --sdk")
    parser.add_argument("--out", type=Path, help="directory for go-dart-notices.py --runtime-licenses")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--refresh", action="store_true",
                      help="fetch every text live and record it in the vendored cache")
    mode.add_argument("--offline", action="store_true",
                      help="fail instead of fetching what the vendored cache lacks")
    args = parser.parse_args()
    if not args.out and not args.refresh:
        parser.error("--out is required unless --refresh is given")
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

    cache = load_cache()
    misses = []

    def obtain(what, url, decode):
        if args.offline:
            sys.exit(f"error: {what} is not in {CACHE}; refresh it with "
                     f"dart-runtime-licenses.py --refresh --version {version} --revision {revision}")
        if not args.refresh:
            misses.append(what)
        return decode(fetch(url))

    recorded = cache["sdks"].get(revision)
    if recorded and recorded["version"] != version:
        sys.exit(f"error: cache.json records {revision} as Dart {recorded['version']}, not {version}")
    if recorded and not args.refresh:
        pins = recorded["pins"]
    else:
        deps = obtain(f"DEPS of Dart {version}", DART_RAW.format(sdk=revision, path="DEPS"),
                      lambda data: data.decode("utf-8"))
        found = dict(re.findall(r'"(\w+_rev)"\s*:\s*"([0-9a-f]{40})"', deps))
        pins = {}
        for name, variable, *_ in COMPONENTS:
            if variable is None:
                continue
            if variable not in found:
                sys.exit(f"error: {variable} not in DEPS at {revision}; update COMPONENTS")
            pins[variable] = found[variable]

    texts, components = [], []
    for name, variable, where, expression, phrases, note in COMPONENTS:
        if variable is None:
            rev = revision
            url = DART_RAW.format(sdk=revision, path=where)
            source = f"https://github.com/dart-lang/sdk/tree/{revision}/{where.rsplit('/', 1)[0]}"
            decode = clean
        else:
            if variable not in pins:
                sys.exit(f"error: {variable} not recorded for Dart {version}; refresh the cache")
            rev = pins[variable]
            host, repo, path = where
            url = GOOGLESOURCE.format(host=host, repo=repo, rev=rev, path=path)
            source = f"https://{host}/{repo}/+/{rev}"
            decode = lambda data: clean(base64.b64decode(data))  # noqa: E731
        text = None if args.refresh else cached_text(cache, name, rev)
        if text is None:
            text = obtain(f"{name} at {rev}", url, decode)
        missing = [phrase for phrase in phrases if phrase.lower() not in text.lower()]
        if missing:
            sys.exit(f"error: {name} license text at {rev} lacks {missing}; review it and update "
                     f"COMPONENTS (expected {expression})")
        filename = slug(name) + "-LICENSE.txt"
        texts.append((name, rev, url.replace("?format=TEXT", ""), filename, text))
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        print(f"{filename}  {rev}  sha256 {digest}")
        entry = {"name": name, "version": rev, "license": expression, "source_url": source,
                 "files": [filename]}
        if note:
            entry["note"] = note
        components.append(entry)

    if args.refresh:
        CACHE.mkdir(parents=True, exist_ok=True)
        cache["sdks"][revision] = {"version": version, "pins": pins}
        for name, rev, url, _, text in texts:
            cache_text(cache, name, rev, url, text)
        # Keep only the texts some recorded SDK uses; drop an SDK by deleting
        # its entry from cache.json and refreshing any SDK.
        used = {(name, recorded["pins"][variable] if variable else sdk_revision)
                for sdk_revision, recorded in cache["sdks"].items()
                for name, variable, *_ in COMPONENTS}
        cache["texts"] = [item for item in cache["texts"]
                          if (item["component"], item["revision"]) in used]
        referenced = {item["file"] for item in cache["texts"]}
        for stale in CACHE.glob("*.txt"):
            if stale.name not in referenced:
                stale.unlink()
        save_cache(cache)
        print(f"recorded Dart {version} in {CACHE / 'cache.json'}; review and commit the directory")
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        for _, _, _, filename, text in texts:
            (args.out / filename).write_text(text, encoding="utf-8")
        manifest = {"sdk_version": version, "sdk_revision": revision, "components": components}
        (args.out / "components.json").write_text(json.dumps(manifest, indent=2) + "\n",
                                                  encoding="utf-8")
        print(f"wrote {args.out / 'components.json'} for Dart {version}")
    if misses:
        print(f"warning: fetched what {CACHE} lacks ({'; '.join(misses)}); record it with "
              f"dart-runtime-licenses.py --refresh --version {version} --revision {revision} "
              f"and commit the result", file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::warning title=Dart runtime licenses not vendored::Dart {version} "
                  f"({revision}) is not in seance/scripts/licenses/dart-runtime; run "
                  f"dart-runtime-licenses.py --refresh and commit it")


if __name__ == "__main__":
    main()
