"""Input detection: what a dropped file is, and where the player's keys are.

Nothing here decrypts anything or reads a key's value. A game file is recognised by its container header (the same
check build_app.input_kind makes) and, for an NSP, by the names in its PFS0 table; the build itself identifies the
version by content hashes, so these are hints for the app's Setup Assistant, not decisions. A keys file is checked by
the names it defines, never by printing or returning a value.
"""
import os
import re
import struct
from pathlib import Path

TOTK_BASE = '0100f2c0115b6000'
TOTK_UPDATE = '0100f2c0115b6800'
KEY_LINE = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=\s*([0-9A-Fa-f]+)\s*$')
# The names the build needs: NCA headers, the application key areas and title keys of tickets.
NEEDED = ('header_key',)
NEEDED_PREFIXES = ('key_area_key_application_', 'titlekek_')
MAX_KEYS_BYTES = 1 << 20


def _pfs0_names(f, limit=64):
    f.seek(0)
    header = f.read(16)
    if len(header) < 16 or header[:4] != b'PFS0':
        return []
    count, table = struct.unpack_from('<II', header, 4)
    if count == 0 or count > 4096 or table > 1 << 20:
        return []
    entries = f.read(count * 24)
    strings = f.read(table)
    if len(entries) != count * 24 or len(strings) != table:
        return []
    names = []
    for i in range(min(count, limit)):
        offset = struct.unpack_from('<I', entries, i * 24 + 16)[0]
        if offset >= table:
            return []
        end = strings.find(b'\0', offset)
        names.append(strings[offset:end if end >= 0 else table].decode('utf-8', 'replace'))
    return names


def inspect_game(path):
    """{'path', 'exists', 'size', 'kind': xci|nsp|nsz|None, 'role': base|update|unknown, 'title': ..., 'note': ...}"""
    p = Path(path).expanduser()
    info = {'path': str(p), 'exists': p.is_file(), 'size': None, 'kind': None, 'role': 'unknown', 'title': None,
            'note': None}
    if not info['exists']:
        info['note'] = 'no such file'
        return info
    info['size'] = p.stat().st_size
    try:
        with p.open('rb') as f:
            magic = f.read(4)
            if magic == b'PFS0':
                info['kind'] = 'nsz' if p.suffix.lower() == '.nsz' else 'nsp'
                names = [n.lower() for n in _pfs0_names(f)]
                if any(n.startswith(TOTK_UPDATE) for n in names):
                    info.update(role='update', title='Tears of the Kingdom update')
                elif any(n.startswith(TOTK_BASE) for n in names):
                    info.update(role='base', title='Tears of the Kingdom')
                elif info['kind'] == 'nsz':
                    info['role'] = 'update'   # build_app.py accepts NSZ only for updates
                else:
                    info['note'] = 'an NSP without a recognisable ticket name; the build identifies it by its hashes'
            else:
                f.seek(0x100)
                if f.read(4) == b'HEAD':
                    info.update(kind='xci', role='base', title='Nintendo Switch game card (XCI)')
                else:
                    info['note'] = 'not an XCI, NSP or NSZ'
    except OSError as e:
        info['note'] = f'cannot read: {e.strerror}'
    return info


def check_keys(path):
    """{'path', 'ok', 'names': count, 'missing': [...]} for a prod.keys file; values are never returned."""
    p = Path(path).expanduser()
    result = {'path': str(p), 'ok': False, 'names': 0, 'missing': list(NEEDED) + [x + '*' for x in NEEDED_PREFIXES]}
    try:
        if not p.is_file() or p.stat().st_size > MAX_KEYS_BYTES:
            return result
        text = p.read_text(errors='replace')
    except OSError:
        return result
    names = set()
    for line in text.splitlines():
        m = KEY_LINE.match(line)
        if m:
            names.add(m.group(1).lower())
    missing = [n for n in NEEDED if n not in names] + \
              [prefix + '*' for prefix in NEEDED_PREFIXES if not any(n.startswith(prefix) for n in names)]
    result.update(ok=not missing, names=len(names), missing=missing)
    return result


def key_candidates(near=None, configured=None):
    home = Path.home()
    found = []
    if configured:
        found.append(Path(configured).expanduser())
    if near:
        folder = Path(near).expanduser()
        folder = folder if folder.is_dir() else folder.parent
        found += [folder / 'prod.keys', folder / 'keys.txt']
    found += [home / '.switch/prod.keys',
              home / 'Library/Application Support/Ryujinx/system/prod.keys',
              home / 'Library/Application Support/Ryujinx/portable/system/prod.keys']
    seen, unique = set(), []
    for p in found:
        key = os.path.normcase(str(p))
        if key not in seen:
            seen.add(key)
            unique.append(p)
    return unique


def find_keys(near=None, configured=None):
    """The first usable keys file, plus every candidate's check (for the app to show what it looked at)."""
    checked = [check_keys(p) for p in key_candidates(near, configured)]
    usable = next((c['path'] for c in checked if c['ok']), None)
    return {'keys': usable, 'checked': [c for c in checked if Path(c['path']).exists()]}


def scan(paths, configured_keys=None):
    """Classify several dropped files at once: the base game, an update, and keys among them."""
    games, keys = [], None
    for raw in paths:
        p = Path(raw).expanduser()
        if p.name.lower().endswith('.keys') or p.name.lower() == 'keys.txt':
            if check_keys(p)['ok']:
                keys = str(p)
            continue
        games.append(inspect_game(p))
    base = next((g for g in games if g['role'] == 'base'), None)
    update = next((g for g in games if g['role'] == 'update'), None)
    if not keys:
        keys = find_keys(base['path'] if base else None, configured_keys)['keys']
    return {'files': games, 'base': base['path'] if base else None, 'update': update['path'] if update else None,
            'keys': keys}
