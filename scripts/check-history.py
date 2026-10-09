#!/usr/bin/env python3
"""Verify preserved source graphs and byte-exact historical tag metadata."""

import base64
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "docs/history/source-refs.json"
FORMAT_VERSION = 1


def git(*arguments, input_bytes=None):
    return subprocess.run(
        ["git", "-C", str(ROOT), *arguments],
        input=input_bytes,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout.decode().strip()


snapshot = json.loads(MANIFEST.read_text())
if snapshot["format"] != FORMAT_VERSION:
    raise ValueError("Unsupported history manifest format")

preservation = snapshot["preservationCommit"]
git("merge-base", "--is-ancestor", preservation, "HEAD")
ref_count = 0
tag_count = 0

for project, source in snapshot["sources"].items():
    # Check the exact import baseline, before intentional integration edits.
    if git("rev-parse", f"{preservation}:{project}") != source["tree"]:
        raise ValueError(f"Imported {project} tree differs from its source")
    if git("rev-parse", source["main"] + "^{tree}") != source["tree"]:
        raise ValueError(f"Source {project} tree mismatch")

    for commit in set(source["refs"].values()):
        git("merge-base", "--is-ancestor", commit, preservation)
    ref_count += len(source["refs"])

    for ref, tag in source["annotatedTags"].items():
        raw = base64.b64decode("".join(tag["tagBase64"]), validate=True)
        if git("hash-object", "-t", "tag", "--stdin", input_bytes=raw) != tag["object"]:
            raise ValueError(f"Historical tag bytes changed: {project} {ref}")
        if not raw.startswith(f"object {tag['commit']}\ntype commit\n".encode()):
            raise ValueError(f"Historical tag target changed: {project} {ref}")
        if source["refs"][ref] != tag["commit"]:
            raise ValueError(f"Historical tag/ref mismatch: {project} {ref}")
        tag_count += 1

print(f"History verified: {ref_count} source refs, {tag_count} annotated tags")
