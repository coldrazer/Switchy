"""Mods: yours to install, yours to remove (docs/ultimate-app-blueprint.md §5).

The runtime reads one folder per game version, <game data>/mods/<version>, with one manifest.tsv (runtime/romfs.c,
scripts/make_mod_manifest.py). The agent keeps each installed mod whole in <game data>/mod-library/<id>/ and composes
the enabled mods of a version into that one folder: their files (hard links where possible) and a manifest made by
make_mod_manifest.py against the RomFS of the built app. Two enabled mods that replace the same file are refused, as the
runtime would refuse them at start. A mods/<version> folder the agent did not compose (a hand-made one) is never
changed; the app offers to import it into the library instead.
"""
import json
import os
import shutil
import threading
from pathlib import Path

from . import REPO, game_data, protocol
from .store import new_id, now

VERSIONS = ('v0', 'v112', 'v121', 'v143')
MARKER = '.mng-composed.json'
_lock = threading.Lock()


def _mod_tool(repo=None):
    import importlib.util
    path = Path(repo or REPO) / 'games/totk/scripts/make_mod_manifest.py'
    spec = importlib.util.spec_from_file_location('make_mod_manifest', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _files(folder):
    """Relative POSIX paths of a mod's files (no manifest, nothing hidden, no links)."""
    out = []
    for p in sorted(folder.rglob('*')):
        rel = p.relative_to(folder)
        if any(part.startswith('.') for part in rel.parts) or rel.as_posix() == 'manifest.tsv':
            continue
        if p.is_symlink():
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{rel}: links are not accepted in a mod')
        if p.is_file():
            out.append(rel.as_posix())
    return out


def _link_or_copy(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


class Mods:
    def __init__(self, store, broadcast, data=None, repo=None):
        self.store, self.broadcast = store, broadcast
        self.data = Path(data) if data else game_data()
        self.repo = repo
        self.library = self.data / 'mod-library'

    def active_folder(self, version):
        return self.data / 'mods' / version

    def folder_state(self, version):
        """'none', 'composed' (ours) or 'manual' (a hand-made manifest we must not touch)."""
        folder = self.active_folder(version)
        if (folder / MARKER).is_file():
            return 'composed'
        if (folder / 'manifest.tsv').is_file():
            return 'manual'
        return 'none'

    def list(self, version=None):
        mods = [m for m in self.store.snapshot('mods') if version in (None, m['version'])]
        for m in mods:
            folder = self.library / m['id']
            m['present'] = folder.is_dir()
            m['files'] = len(_files(folder)) if m['present'] else 0
        versions = [version] if version else list(VERSIONS)
        return {'mods': mods, 'folders': {v: {'path': str(self.active_folder(v)), 'state': self.folder_state(v)}
                                          for v in versions}}

    def _romfs(self, version):
        for app in self.store.snapshot('library'):
            if app['version'] == version and app.get('platform') == 'macos':
                romfs = Path(app['path']) / f'Contents/Resources/totk/extracted/{version}/romfs'
                if (romfs / 'romfs.bin').is_file() and (romfs / 'runtime-index.bin').is_file():
                    return romfs
        raise protocol.ProtocolError(protocol.FAILED, f'no built app for game version {version}: build it first, '
                                                      'mods are checked against its game data')

    def add(self, source, version, name=None, enabled=True):
        if version not in VERSIONS:
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'version must be one of {", ".join(VERSIONS)}')
        source = Path(source).expanduser().resolve()
        if not source.is_dir():
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{source} is not a folder')
        if self.data.resolve() in (source, *source.parents):
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, 'choose a folder outside the game data folder')
        files = _files(source)
        if not files:
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{source} holds no files')
        mod_id = new_id()
        target = self.library / mod_id
        staging = self.library / f'.{mod_id}.partial'
        try:
            for rel in files:
                dst = staging / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source / rel, dst)
            staging.rename(target)
        except OSError as e:
            shutil.rmtree(staging, ignore_errors=True)
            raise protocol.ProtocolError(protocol.FAILED, f'copying the mod failed: {e}') from None
        mod = {'id': mod_id, 'name': name or source.name, 'version': version, 'enabled': bool(enabled), 'added': now(),
               'source': str(source)}
        self.store.set_mods(self.store.snapshot('mods') + [mod])
        result = {'mod': mod}
        if enabled:
            try:
                result['apply'] = self.apply(version)
            except protocol.ProtocolError as e:
                # Keep the mod, but disabled, so the active folder stays the last good one.
                self._set(mod_id, enabled=False)
                result['mod']['enabled'] = False
                result['apply_error'] = e.message
        self.broadcast({'event': 'mods'})
        return result

    def _set(self, mod_id, **fields):
        mods = self.store.snapshot('mods')
        for m in mods:
            if m['id'] == mod_id:
                m.update(fields)
                self.store.set_mods(mods)
                return m
        raise protocol.ProtocolError(protocol.NOT_FOUND, f'no mod {mod_id}')

    def enable(self, mod_id, enabled):
        before = next((m for m in self.store.snapshot('mods') if m['id'] == mod_id), None)
        if before is None:
            raise protocol.ProtocolError(protocol.NOT_FOUND, f'no mod {mod_id}')
        mod = self._set(mod_id, enabled=bool(enabled))
        try:
            result = self.apply(mod['version'])
        except protocol.ProtocolError:
            self._set(mod_id, enabled=before['enabled'])
            raise
        self.broadcast({'event': 'mods'})
        return {'mod': mod, 'apply': result}

    def remove(self, mod_id):
        mods = self.store.snapshot('mods')
        mod = next((m for m in mods if m['id'] == mod_id), None)
        if mod is None:
            raise protocol.ProtocolError(protocol.NOT_FOUND, f'no mod {mod_id}')
        self.store.set_mods([m for m in mods if m['id'] != mod_id])
        result = {'removed': mod_id}
        if mod['enabled']:
            try:
                result['apply'] = self.apply(mod['version'])
            except protocol.ProtocolError as e:
                result['apply_error'] = e.message
        shutil.rmtree(self.library / mod_id, ignore_errors=True)
        self.broadcast({'event': 'mods'})
        return result

    def import_manual(self, version, name=None):
        """Move a hand-made mods/<version> folder into the library as one mod, then compose it back."""
        if self.folder_state(version) != 'manual':
            raise protocol.ProtocolError(protocol.CONFLICT, f'mods/{version} is not a hand-made mod folder')
        folder = self.active_folder(version)
        mod_id = new_id()
        self.library.mkdir(parents=True, exist_ok=True)
        os.replace(folder, self.library / mod_id)
        (self.library / mod_id / 'manifest.tsv').unlink(missing_ok=True)
        mod = {'id': mod_id, 'name': name or f'Imported mods ({version})', 'version': version, 'enabled': True,
               'added': now(), 'source': str(folder)}
        self.store.set_mods(self.store.snapshot('mods') + [mod])
        result = {'mod': mod}
        try:
            result['apply'] = self.apply(version)
        except protocol.ProtocolError as e:
            self._set(mod_id, enabled=False)
            result['mod']['enabled'] = False
            result['apply_error'] = e.message
        self.broadcast({'event': 'mods'})
        return result

    def apply(self, version):
        """Compose the enabled mods of a version into mods/<version>; returns a summary or raises ProtocolError."""
        with _lock:
            state = self.folder_state(version)
            if state == 'manual':
                raise protocol.ProtocolError(protocol.CONFLICT, f'{self.active_folder(version)} holds a hand-made mod; '
                                                                'import it first (mods.import) so the agent can manage it')
            enabled = [m for m in self.store.snapshot('mods') if m['version'] == version and m['enabled']]
            folder = self.active_folder(version)
            if not enabled:
                if state == 'composed':
                    shutil.rmtree(folder)
                return {'version': version, 'mods': 0, 'files': 0}
            owner = {}
            for m in enabled:
                for rel in _files(self.library / m['id']):
                    if rel in owner:
                        raise protocol.ProtocolError(protocol.CONFLICT, f'"{owner[rel]["name"]}" and "{m["name"]}" both '
                                                                        f'change {rel}; disable one of them')
                    owner[rel] = m
            romfs = self._romfs(version)
            staging = folder.with_name(f'.{version}.composing')
            shutil.rmtree(staging, ignore_errors=True)
            try:
                for rel, m in owner.items():
                    _link_or_copy(self.library / m['id'] / rel, staging / rel)
                lines, same, added, misspelt = _mod_tool(self.repo).manifest(staging, romfs)
                if misspelt:
                    name, real = misspelt[0]
                    raise protocol.ProtocolError(protocol.FAILED, f'"{owner[name]["name"]}": {name} is not a file of this '
                                                                  f'game version (it has {real}; paths are case-sensitive)')
                if not lines:
                    raise protocol.ProtocolError(protocol.FAILED, 'the enabled mods change no file of the game')
                (staging / 'manifest.tsv').write_text(
                    '# path\tsize\tsha256\toriginal_sha256 (composed by the MacNativeGames agent)\n' + '\n'.join(lines) + '\n')
                (staging / MARKER).write_text(json.dumps({'mods': [m['id'] for m in enabled], 'composed': now()}))
                old = folder.with_name(f'.{version}.previous')
                shutil.rmtree(old, ignore_errors=True)
                if folder.exists():
                    os.replace(folder, old)
                os.replace(staging, folder)
                shutil.rmtree(old, ignore_errors=True)
            finally:
                shutil.rmtree(staging, ignore_errors=True)
            return {'version': version, 'mods': len(enabled), 'files': len(lines), 'added': len(added),
                    'unchanged': len(same)}
