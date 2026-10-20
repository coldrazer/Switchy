#!/usr/bin/env python3
"""The native read-only RomFS backend: build/<version>/romfs_config.h and the player's runtime-index.bin.

The header holds only version constants, the RomFS image's size and SHA-256 from assets/expected-v*.json, so the game
binary compiles without any player data (docs/ultimate-app-blueprint.md §3). runtime-index.bin is the bounded binary
index of the player's extracted RomFS; it is built only from an index.json whose image matches the same pinned values,
so a damaged or different RomFS still stops the build. Its digest goes into runtime-manifest.txt
(scripts/prepare_runtime_manifest.py), not into the binary.

    prepare_romfs_backend.py [--version v0|v112|v121|v143] [--header-only]
"""
import argparse
import json
import os
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_FILES = {'v0': 'expected-v1.0.0.json', 'v112': 'expected-v1.1.2.json',
                  'v121': 'expected-v1.2.1.json', 'v143': 'expected-v1.4.3.json'}
INDEX_MAGIC = b'TOTKRFS1'


class RomfsError(Exception):
    pass


def pinned(version, assets=None):
    """(size, sha256) of the version's RomFS image from the checked-in expectations."""
    data = json.loads(((assets or ROOT / 'assets') / EXPECTED_FILES[version]).read_text())
    size, digest = data['romfs']['size'], data['romfs']['sha256']
    if not isinstance(size, int) or size <= 0 or not isinstance(digest, str) or len(digest) != 64 or \
            any(c not in '0123456789abcdef' for c in digest):
        raise RomfsError(f'{EXPECTED_FILES[version]}: malformed romfs size or sha256')
    return size, digest


def header_text(size, digest):
    return f'#define ROMFS_IMAGE_SIZE {size}ULL\n#define ROMFS_IMAGE_SHA256 "{digest}"\n'


def output_dir(version, root=ROOT):
    return root / ('build' if version == 'v0' else f'build/{version}')


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.partial')
    tmp.write_bytes(data)
    os.replace(tmp, path)


def write_header(version, root=ROOT, assets=None):
    path = output_dir(version, root) / 'romfs_config.h'
    text = header_text(*pinned(version, assets)).encode()
    if not path.is_file() or path.read_bytes() != text:   # unchanged bytes keep make from relinking
        write_atomic(path, text)
    return path


def index_bytes(files):
    """The TOTKRFS1 index: a sorted table of (offset, size, name offset, name length) and NUL-terminated names."""
    strings, rows, previous = bytearray(), bytearray(), None
    for item in files:
        path = item['path']
        if previous is not None and not previous < path:
            raise RomfsError(f'RomFS index paths are not sorted and unique at {path!r}')
        previous = path
        name = path.encode() + b'\0'
        rows += struct.pack('<QQII', item['offset'], item['size'], len(strings), len(name))
        strings += name
    return struct.pack('<8sQQ', INDEX_MAGIC, len(files), 24 + len(rows)) + bytes(rows) + bytes(strings)


def build_index(version, root=ROOT, assets=None):
    """runtime-index.bin from the player's verified index.json, which must describe the pinned image."""
    folder = root / f'extracted/{version}/romfs'
    size, digest = pinned(version, assets)
    try:
        manifest = json.loads((folder / 'index.json').read_text())
    except (OSError, ValueError) as e:
        raise RomfsError(f'no readable RomFS index.json in {folder}: {e}') from None
    if manifest.get('status') != 'pass':
        raise RomfsError('the extracted RomFS did not pass verification')
    if manifest.get('romfs_sha256') != digest or manifest.get('romfs_size') != size:
        raise RomfsError(f'the extracted RomFS is not the pinned {EXPECTED_FILES[version]} image '
                         f'(sha256 {str(manifest.get("romfs_sha256"))[:16]}..., size {manifest.get("romfs_size")})')
    image = folder / 'romfs.bin'
    if image.is_file() and image.stat().st_size != size:
        raise RomfsError(f'{image} is {image.stat().st_size} bytes, not {size}')
    if not image.is_file() and not (folder / 'romfs.bin.000').is_file():
        raise RomfsError(f'no RomFS image in {folder}')
    for item in manifest['files']:
        if item['offset'] < 0 or item['size'] < 0 or item['offset'] + item['size'] > size:
            raise RomfsError(f'RomFS file {item["path"]!r} lies outside the image')
    data = index_bytes(manifest['files'])
    write_atomic(folder / 'runtime-index.bin', data)
    return len(manifest['files']), len(data)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--version', choices=tuple(EXPECTED_FILES), default='v0')
    parser.add_argument('--header-only', action='store_true', help='write only the version header (no player data needed)')
    args = parser.parse_args(argv)
    try:
        header = write_header(args.version)
        report = {'header': str(header.relative_to(ROOT))}
        if not args.header_only:
            files, size = build_index(args.version)
            report.update(files=files, index_bytes=size)
    except RomfsError as e:
        print(f'prepare_romfs_backend: {e}', file=sys.stderr)
        return 1
    print(json.dumps(report))
    return 0


if __name__ == '__main__':
    sys.exit(main())
