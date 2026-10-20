#!/usr/bin/env python3
"""Write runtime-manifest.txt into the RomFS directory (runtime/runtime_manifest.h has the format).

It carries what is genuinely this player's: the digest of the runtime-index.bin made from their RomFS
(scripts/prepare_romfs_backend.py) and the six shared fonts, bound by the bytes actually on disk. A font from another
firmware version is accepted when build_app.py validated it; this script checks that the font folder's manifest.json
agrees with its files (type order, sizes and SHA-256 of the real bytes) before writing anything.

    prepare_runtime_manifest.py [--version v0|v112|v121|v143] [--romfs DIR] [--fonts DIR]
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAME = 'runtime-manifest.txt'
FORMAT = 1
FONT_COUNT = 6
FONT_MAX_BYTES = 64 << 20
VERSIONS = ('v0', 'v112', 'v121', 'v143')


class ManifestError(Exception):
    pass


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
    return h.hexdigest()


def _hex64(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def _relative(path):
    if not path or path.startswith('/') or '\\' in path or '\t' in path or '\n' in path or '\r' in path:
        return False
    return all(part not in ('', '.', '..') for part in path.split('/'))


def render(index_sha256, fonts):
    """The manifest text. fonts: six dicts with path, file_bytes, font_bytes, sha256, in type order."""
    if not _hex64(index_sha256):
        raise ManifestError('romfs_index_sha256 is not 64 lowercase hex digits')
    if len(fonts) != FONT_COUNT:
        raise ManifestError(f'{len(fonts)} fonts, expected {FONT_COUNT}')
    lines = [f'format\t{FORMAT}', f'romfs_index_sha256\t{index_sha256}']
    for kind, font in enumerate(fonts):
        path, size, font_size, digest = font['path'], font['file_bytes'], font['font_bytes'], font['sha256']
        if not _relative(path) or len(path.encode()) >= 1024:
            raise ManifestError(f'font {kind}: path {path!r} is not a plain relative path')
        if not (isinstance(size, int) and 8 < size <= FONT_MAX_BYTES and font_size == size - 8):
            raise ManifestError(f'font {kind}: sizes {size} / {font_size} are not a BFTTF file and its font')
        if not _hex64(digest):
            raise ManifestError(f'font {kind}: sha256 is not 64 lowercase hex digits')
        lines.append(f'font\t{kind}\t{path}\t{size}\t{font_size}\t{digest}')
    return ''.join(line + '\n' for line in lines)


def parse(text):
    """The inverse of render, as strict as runtime_manifest.c (tests check that they agree)."""
    if '\0' in text or '\r' in text or not text.endswith('\n') or len(text.encode()) > 64 * 1024:
        raise ManifestError('not a manifest text')
    lines = text[:-1].split('\n')
    if len(lines) != 2 + FONT_COUNT:
        raise ManifestError(f'{len(lines)} lines, expected {2 + FONT_COUNT}')
    if lines[0] != f'format\t{FORMAT}':
        raise ManifestError('bad format line')
    key, _, digest = lines[1].partition('\t')
    if key != 'romfs_index_sha256' or not _hex64(digest):
        raise ManifestError('bad romfs_index_sha256 line')
    fonts = []
    for kind, line in enumerate(lines[2:]):
        fields = line.split('\t')
        if len(fields) != 6 or fields[0] != 'font' or fields[1] != str(kind):
            raise ManifestError(f'bad font line {kind}')
        if any(not f.isdigit() or (len(f) > 1 and f[0] == '0') for f in fields[3:5]):
            raise ManifestError(f'font {kind}: sizes are not canonical decimals')
        fonts.append(dict(path=fields[2], file_bytes=int(fields[3]), font_bytes=int(fields[4]), sha256=fields[5]))
    if render(digest, fonts) != text:
        raise ManifestError('manifest does not round-trip')
    return digest, fonts


def font_rows(folder, root):
    """The six fonts of a folder written by build_app.py (manifest.json + <type>-<name>.bfttf), checked byte by byte."""
    try:
        manifest = json.loads((folder / 'manifest.json').read_text())
        rows = manifest['fonts']
        if manifest['status'] != 'pass' or [row['type'] for row in rows] != list(range(FONT_COUNT)):
            raise ValueError('status is not pass or font types are not 0..5 in order')
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise ManifestError(f'invalid shared-font manifest in {folder}: {e}') from None
    fonts = []
    for row in rows:
        path = folder / f"{row['type']}-{row['name']}.bfttf"
        if not path.is_file():
            raise ManifestError(f'missing shared font {path}')
        size = path.stat().st_size
        if size != row['bfttf_bytes'] or row['font_bytes'] != size - 8:
            raise ManifestError(f'shared font {path.name}: {size} bytes on disk, manifest says {row["bfttf_bytes"]}')
        digest = sha256(path)
        if digest != row['sha256']:
            raise ManifestError(f'shared font {path.name}: its bytes do not match the manifest SHA-256')
        try:
            relative = os.path.relpath(path.resolve(), root.resolve())
        except ValueError:
            relative = '..'
        if not _relative(relative):
            raise ManifestError(f'shared fonts must be inside {root} so the runtime can find them by a relative path')
        fonts.append(dict(path=relative, file_bytes=size, font_bytes=size - 8, sha256=digest))
    return fonts


def write(romfs, fonts_dir, root=ROOT):
    index = romfs / 'runtime-index.bin'
    if not index.is_file():
        raise ManifestError(f'{index} is missing; run scripts/prepare_romfs_backend.py first')
    text = render(sha256(index), font_rows(fonts_dir, root))
    path = romfs / NAME
    if not path.is_file() or path.read_text() != text:
        tmp = path.with_name(NAME + '.partial')
        tmp.write_text(text)
        os.replace(tmp, path)
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--version', choices=VERSIONS, default='v0')
    parser.add_argument('--romfs', type=Path, help='RomFS directory (default extracted/<version>/romfs)')
    parser.add_argument('--fonts', type=Path, help='shared-font directory (default extracted/firmware/shared-fonts)')
    parser.add_argument('--root', type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    romfs = args.romfs or root / f'extracted/{args.version}/romfs'
    fonts = args.fonts or root / 'extracted/firmware/shared-fonts'
    try:
        path = write(romfs, fonts, root)
    except ManifestError as e:
        print(f'prepare_runtime_manifest: {e}', file=sys.stderr)
        return 1
    print(json.dumps({'manifest': str(path), 'fonts': FONT_COUNT}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
