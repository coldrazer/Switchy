"""com.macnativegames.agent: the headless service behind MacNativeGames.app (docs/ultimate-app-blueprint.md §2, Phase 2).

The agent owns the state; the app is a client. It runs as a per-user LaunchAgent, so a build survives the app closing.
It keeps a job queue and a state store, runs each build as a supervised subprocess (mng_agent/runner.py) over the step
graph of build_app.py, and answers clients over a Unix socket with newline-delimited JSON (mng_agent/protocol.py).

Everything here also works from a terminal: python3 -m mng_agent --help.
"""
import os
from pathlib import Path

VERSION = '1.0.0'
PROTOCOL = 1
LABEL = 'com.macnativegames.agent'
REPO = Path(__file__).resolve().parents[1]


def agent_home():
    """The agent's folder: state, job logs, the socket. MNG_AGENT_HOME overrides it (tests, a second agent)."""
    override = os.environ.get('MNG_AGENT_HOME')
    if override:
        return Path(override).expanduser()
    return Path.home() / 'Library/Application Support/MacNativeGames/agent'


def game_data():
    """The game's own data folder, as app/launcher.m names it (saves, shader cache, mods, controls)."""
    override = os.environ.get('MNG_GAME_DATA')
    if override:
        return Path(override).expanduser()
    return Path.home() / 'Library/Application Support/MacNativeGames/TOTK'


def game_logs():
    override = os.environ.get('MNG_GAME_LOGS')
    if override:
        return Path(override).expanduser()
    return Path.home() / 'Library/Logs/MacNativeGames'
