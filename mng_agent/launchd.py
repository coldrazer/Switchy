"""The per-user LaunchAgent that keeps the agent running: ~/Library/LaunchAgents/com.macnativegames.agent.plist."""
import os
import plistlib
import platform
import subprocess
import sys
import time
from pathlib import Path

from . import LABEL, REPO, agent_home


def plist_path():
    return Path.home() / 'Library/LaunchAgents' / f'{LABEL}.plist'


def plist(python=None, repo=None, home=None):
    python, repo, home = python or sys.executable, Path(repo or REPO), Path(home or agent_home())
    env = {'PYTHONPATH': str(repo), 'PYTHONUNBUFFERED': '1',
           # The build looks for Homebrew tools; launchd starts with a minimal PATH.
           'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'}
    if os.environ.get('MNG_AGENT_HOME'):
        env['MNG_AGENT_HOME'] = str(home)
    return {
        'Label': LABEL,
        'ProgramArguments': [str(python), '-m', 'mng_agent', 'serve'],
        'WorkingDirectory': str(repo),
        'EnvironmentVariables': env,
        'RunAtLoad': True,
        # Restart after a crash, not after a clean stop (mng_agent stop).
        'KeepAlive': {'SuccessfulExit': False},
        'ProcessType': 'Background',
        'LowPriorityBackgroundIO': False,
        'StandardOutPath': str(home / 'agent.err'),
        'StandardErrorPath': str(home / 'agent.err'),
    }


def _domain():
    return f'gui/{os.getuid()}'


def _launchctl(*args):
    return subprocess.run(['launchctl', *args], capture_output=True, text=True)


def install(python=None, repo=None, home=None):
    if platform.system() != 'Darwin':
        raise RuntimeError('the LaunchAgent is macOS only; run "python3 -m mng_agent serve" in a terminal instead')
    home = Path(home or agent_home())
    home.mkdir(parents=True, exist_ok=True)
    path = plist_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    data = plistlib.dumps(plist(python, repo, home))
    tmp = path.with_name(path.name + '.partial')
    tmp.write_bytes(data)
    os.replace(tmp, path)
    _launchctl('bootout', f'{_domain()}/{LABEL}')   # an older copy; not an error when none is loaded
    # bootstrap can return EIO while the domain is still settling after bootout; retry briefly.
    error = None
    for attempt in range(4):
        r = _launchctl('bootstrap', _domain(), str(path))
        if not r.returncode:
            return str(path)
        error = (r.stderr or r.stdout).strip()
        if _launchctl('print', f'{_domain()}/{LABEL}').returncode == 0:
            return str(path)   # it did load; the command just reported a transient failure
        time.sleep(0.4 * (attempt + 1))
    raise RuntimeError(f'launchctl bootstrap failed: {error}')


def uninstall():
    if platform.system() != 'Darwin':
        raise RuntimeError('the LaunchAgent is macOS only')
    _launchctl('bootout', f'{_domain()}/{LABEL}')
    path = plist_path()
    existed = path.exists()
    path.unlink(missing_ok=True)
    return existed


def status():
    if platform.system() != 'Darwin':
        return {'installed': False, 'loaded': False, 'supported': False}
    loaded = _launchctl('print', f'{_domain()}/{LABEL}').returncode == 0
    return {'installed': plist_path().exists(), 'loaded': loaded, 'supported': True, 'plist': str(plist_path())}
