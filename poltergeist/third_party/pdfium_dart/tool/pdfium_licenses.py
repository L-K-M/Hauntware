#!/usr/bin/env python3
"""Copy PDFium's license texts from the pinned pdfium-binaries archives into LICENSE.

hook/build.dart bundles libpdfium from bblanchon/pdfium-binaries but keeps
only the library, so the archive's LICENSE and licenses/ texts (PDFium and
the libraries compiled into it) are appended to this package's LICENSE as
Flutter license chunks: a line of 80 hyphens, the chunk's name, a blank
line, the text. Flutter then puts them into every Poltergeist NOTICES.

Every archive the apps ship is downloaded, checked against its SHA-256 in
pdfium_licenses.json, and read. The run fails when an archive has a
license file no component lists, when a listed file is in no archive, or
when two archives disagree on a text (line endings and comment markers
aside). --check compares instead of writing. Python 3.8+ standard library.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import tarfile
import urllib.request

PACKAGE = Path(__file__).resolve().parents[1]
SEPARATOR = '\n' + '-' * 80 + '\n'
OWN_CHUNK = 'pdfium_dart'
RELEASE_PAGE = 'https://github.com/bblanchon/pdfium-binaries/releases/tag/'


def download(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Hauntware PDFium notices'})
    with urllib.request.urlopen(request, timeout=180) as response:
        return response.read()


def clean(data):
    """The text as shipped, as UTF-8 with LF line endings and no trailing blanks."""
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        text = data.decode('latin-1')  # FreeType's FTL.TXT writes its (c) sign in Latin-1
    lines = [line.rstrip() for line in text.replace('\r\n', '\n').split('\n')]
    return '\n'.join(lines).strip('\n')


def canonical(text):
    """For comparing archives: the mac archive comments some texts with //."""
    return '\n'.join(re.sub(r'^// ?', '', line) for line in text.split('\n')).strip('\n')


def license_members(archive):
    """LICENSE and licenses/* of one pdfium-binaries archive, cleaned."""
    found = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        for member in tar.getmembers():
            name = member.name[2:] if member.name.startswith('./') else member.name
            if member.isfile() and (name == 'LICENSE' or name.startswith('licenses/')):
                found[name] = clean(tar.extractfile(member).read())
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--check', action='store_true', help='fail if LICENSE differs instead of writing it')
    parser.add_argument('--archive-dir', type=Path, help='read the archives from here instead of downloading')
    args = parser.parse_args()

    config = json.loads((PACKAGE / 'tool/pdfium_licenses.json').read_text())
    texts, problems = {}, []
    for name, sha256 in config['archives'].items():
        data = (args.archive_dir / name).read_bytes() if args.archive_dir else download(f"{config['base_url']}/{name}")
        if hashlib.sha256(data).hexdigest() != sha256:
            sys.exit(f'error: {name} does not match its pinned SHA-256')
        for member, text in license_members(data).items():
            first = texts.setdefault(member, (name, text))
            if canonical(first[1]) != canonical(text):
                problems.append(f'{member} differs between {first[0]} and {name}')

    listed = {file for component in config['components'] for file in component['files']}
    problems += [f'{member} is in the archives but no component lists it' for member in sorted(set(texts) - listed)]
    problems += [f'{file} is listed but in no archive' for file in sorted(listed - set(texts))]

    source = RELEASE_PAGE + config['release'].replace('/', '%2F')
    chunks = []
    for component in config['components']:
        files = ', '.join(component['files'])
        preamble = (f"Compiled into the PDFium library Poltergeist bundles: {files} of\n"
                    f"pdfium-binaries {config['release']} ({source}).")
        if component['name'] == 'PDFium':
            preamble += ("\nThe macOS and iOS apps also embed PDFium.xcframework\n"
                         "(https://github.com/espresso3389/pdfium-xcframework), built from\n"
                         "the same PDFium release.")
        body = '\n\n'.join(texts[file][1] for file in component['files'] if file in texts)
        # A rule of exactly 80 hyphens (cpu_features has two) would split the
        # chunk in Flutter's parser; one hyphen less keeps the rule a rule.
        body = re.sub(r'(?m)^-{80}$', '-' * 79, body)
        chunk = f"{component['name']}\n\n{preamble}\n\n{body}\n"
        if SEPARATOR in '\n' + chunk:
            problems.append(f"{component['name']}: a text contains the chunk separator")
        chunks.append(chunk)
    if problems:
        sys.exit('error: ' + '\nerror: '.join(problems))

    # This package's own MIT chunk stays first and byte for byte (CRLF, as
    # upstream ships it, so Flutter still merges it with pdfium_flutter's),
    # named so Flutter splits the file.
    with open(PACKAGE / 'LICENSE', encoding='utf-8', newline='') as file:
        current = file.read()
    own = current.split(SEPARATOR)[0]
    if not own.startswith(OWN_CHUNK + '\n\n'):
        own = f'{OWN_CHUNK}\n\n{own}'
    wanted = SEPARATOR.join([own] + chunks)
    if args.check:
        if current != wanted:
            sys.exit('error: LICENSE differs from the pinned archives; run tool/pdfium_licenses.py')
        print(f'LICENSE matches {len(config["archives"])} pinned archives ({len(chunks)} chunks)')
        return
    with open(PACKAGE / 'LICENSE', 'w', encoding='utf-8', newline='') as file:
        file.write(wanted)
    print(f'Wrote {len(chunks)} PDFium chunks from {len(config["archives"])} pinned archives')


if __name__ == '__main__':
    main()
