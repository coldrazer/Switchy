"""Known titles: the id in a file name, the name to show, and whether this runtime can build it.

The list lives in titles.json at the repository root so the build and the app answer the same question. A name is
only a hint (the pipeline still checks the file by content); this is what lets the app say "this is Hyrule Warriors,
which this runtime cannot build" before a build starts.
"""
import json
import re
from pathlib import Path

from . import REPO

_CACHE = None
_BRACKETED = re.compile(r'\[([0-9A-Fa-f]{16})\]')
_TICKET = re.compile(r'(?<![0-9A-Fa-f])([0-9A-Fa-f]{16})0{16}(?![0-9A-Fa-f])')
_ANY = re.compile(r'(?<![0-9A-Fa-f])([0-9A-Fa-f]{16})(?![0-9A-Fa-f])')


def all():
    global _CACHE
    if _CACHE is None:
        data = json.loads((REPO / 'titles.json').read_text())
        _CACHE = {t['id'].upper(): t for t in data['titles']}
    return _CACHE


def supported():
    return {title_id for title_id, title in all().items() if title.get('supported')}


def identify(path):
    """The title id in a file name like 'TOTK [0100F2C0115B6000][v0].xci', or None."""
    name = Path(path).name
    for pattern in (_BRACKETED, _TICKET, _ANY):
        match = pattern.search(name)
        if match:
            return match.group(1).upper()
    return None
