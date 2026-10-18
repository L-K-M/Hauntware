#!/usr/bin/env python3
"""Restore the additional fonts and NOTICES from pinned upstream releases."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile

PACKAGE = Path(__file__).resolve().parents[1]
SEPARATOR = '\n' + '-' * 80 + '\n'


def verified(data, expected, source):
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f'Checksum mismatch: {source}')
    return data


def download(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Hauntware fonts'})
    with urllib.request.urlopen(request, timeout=180) as response:
        return response.read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Verify local bytes without network access')
    args = parser.parse_args()
    sources = json.loads((PACKAGE / 'tool/font_releases.json').read_text())
    chunks = (PACKAGE / 'LICENSE').read_text().split(SEPARATOR)
    imported = {family['name'] for source in sources for family in source['families']}
    preserved = [chunk for chunk in chunks if chunk.split('\n\n', 1)[0] not in imported]
    restored = []
    count = 0
    for source in sources:
        if args.check:
            for family in source['families']:
                for face in family['files']:
                    path = PACKAGE / face['path']
                    verified(path.read_bytes(), face['sha256'], path)
                    count += 1
            continue

        data = verified(download(source['url']), source['sha256'], source['url'])
        with zipfile.ZipFile(io.BytesIO(data)) as outer:
            license_source = source['license']['source']
            license_data = download(license_source) if license_source.startswith('https:') else outer.read(license_source)
            verified(license_data, source['license']['sha256'], license_source)
            archive = outer
            if 'nested_archive' in source:
                archive = zipfile.ZipFile(io.BytesIO(outer.read(source['nested_archive'])))
            for family in source['families']:
                credit = family.get('copyright', '')
                text = (credit + '\n\n' if credit else '') + '\n'.join(
                    line.rstrip() for line in license_data.decode().strip().splitlines()
                )
                restored.append(family['name'] + '\n\n' + text + '\n')
                for face in family['files']:
                    data = verified(archive.read(face['member']), face['sha256'], face['member'])
                    path = PACKAGE / face['path']
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                    count += 1
    if not args.check:
        (PACKAGE / 'LICENSE').write_text(SEPARATOR.join(preserved + restored))
    print(f'Verified {count} unmodified font files')


if __name__ == '__main__':
    main()
