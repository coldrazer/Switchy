"""Diagnostics: one report of what the agent knows, and an archive to attach to an issue.

The archive holds the report, the agent's job logs and the tails of the game's logs. It never holds a keys file, a
save, game data or the shader cache; key paths are reported only as present or not.
"""
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

from . import PROTOCOL, REPO, VERSION, game_data, game_logs


def _git(repo):
    try:
        r = subprocess.run(['git', '-C', str(repo), 'rev-parse', '--short', 'HEAD'], capture_output=True, text=True,
                           timeout=5)
        return r.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def _free_gb(path):
    p = Path(path)
    while not p.exists() and p != p.parent:
        p = p.parent
    try:
        return round(shutil.disk_usage(p).free / 2**30, 1)
    except OSError:
        return None


def _size(folder, limit=200000):
    total, n = 0, 0
    for root, _, files in os.walk(folder):
        for name in files:
            n += 1
            if n > limit:
                return None
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def toolchain():
    """The build prerequisites build_app.py checks, without failing: what is there and what is missing."""
    found = {'platform': f'{platform.system()} {platform.machine()}', 'macos': platform.mac_ver()[0] or None}
    search = os.pathsep.join(['/opt/homebrew/bin', '/usr/local/bin', os.environ.get('PATH', '')])

    def which(*names):
        for name in names:
            path = shutil.which(name, path=search)
            if path:
                return path
        return None
    found['python3.14'] = which('python3.14', 'python3.15')
    found['git'] = which('git')
    found['xcrun'] = which('xcrun')
    found['homebrew_opus'] = Path('/opt/homebrew/opt/opus/lib').is_dir()
    found['homebrew_libvpx'] = Path('/opt/homebrew/opt/libvpx/lib').is_dir()
    ok = (platform.system() == 'Darwin' and platform.machine() == 'arm64' and
          int((platform.mac_ver()[0] or '0').split('.')[0]) >= 26 and all(found[k] for k in
          ('python3.14', 'git', 'xcrun', 'homebrew_opus', 'homebrew_libvpx')))
    found['ready'] = ok
    return found


def report(store, jobs, home):
    settings = store.snapshot('settings')
    all_jobs = store.snapshot('jobs')
    failed = [j for j in all_jobs if j['status'] == 'failed']
    last_failed = max(failed, key=lambda j: j['created']) if failed else None
    data = game_data()
    logs = game_logs()
    game_log_files = sorted((p for p in logs.glob('*') if p.is_file()), key=lambda p: p.stat().st_mtime,
                            reverse=True)[:10] if logs.is_dir() else []
    redacted = dict(settings)
    for key in ('keys',):
        redacted[key] = 'set' if settings.get(key) else None
    repo = Path(settings.get('repo') or REPO)
    return {
        'generated': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'agent': {'version': VERSION, 'protocol': PROTOCOL, 'pid': os.getpid(), 'python': sys.version.split()[0],
                  'home': str(home)},
        'repo': {'path': str(repo), 'commit': _git(repo), 'build_app': (repo / 'build_app.py').is_file()},
        'toolchain': toolchain(),
        'settings': redacted,
        'disk_free_gb': {'agent': _free_gb(home), 'output': _free_gb(settings.get('output_dir') or Path.home()),
                         'work': _free_gb(settings.get('work_dir') or Path.home())},
        'jobs': {'total': len(all_jobs), 'by_status': {s: sum(j['status'] == s for j in all_jobs) for s in
                                                       ('queued', 'running', 'succeeded', 'failed', 'cancelled')}},
        'last_failure': None if not last_failed else {
            'job': last_failed['id'], 'error': last_failed['error'],
            'step': next((s['name'] for s in last_failed['steps'] if s['status'] == 'failed'), None),
            'log_tail': jobs.log_tail(last_failed['id'], 80)},
        'library': store.snapshot('library'),
        'game_data': {'path': str(data), 'exists': data.is_dir(),
                      'shader_cache_bytes': _size(data / 'shader-cache') if (data / 'shader-cache').is_dir() else 0,
                      'mods': sorted(p.name for p in (data / 'mods').iterdir()) if (data / 'mods').is_dir() else []},
        'game_logs': [{'name': p.name, 'bytes': p.stat().st_size, 'modified': p.stat().st_mtime} for p in game_log_files],
        'recovered_state': store.data.get('recovered_from'),
    }


def export(store, jobs, home, destination):
    """Write a .zip with the report, job logs and game log tails; returns its path."""
    destination = Path(destination).expanduser()
    if destination.is_dir():
        destination = destination / f'MacNativeGames-diagnostics-{time.strftime("%Y%m%d-%H%M%S")}.zip'
    if destination.suffix.lower() != '.zip':
        raise ValueError('the diagnostics archive must end in .zip')
    data = report(store, jobs, home)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('report.json', json.dumps(data, indent=2, default=str))
        for log in sorted((Path(home) / 'jobs').glob('*.log'))[-20:]:
            z.write(log, f'jobs/{log.name}')
        for item in data['game_logs'][:5]:
            path = game_logs() / item['name']
            try:
                with open(path, 'rb') as f:
                    f.seek(max(0, path.stat().st_size - 512 * 1024))
                    z.writestr(f'game-logs/{item["name"]}', f.read())
            except OSError:
                pass
        for name in ('agent.log', 'agent.log.1', 'agent.err'):
            path = Path(home) / name
            if path.is_file():
                z.write(path, name)
    return str(destination)
