"""Settings the app shows: build settings (stored as-is) and game settings, which become the TOTK_* environment the
game reads at start. Only documented, player-facing switches are offered; each value is checked here the same way the
runtime checks it, so a bad value is refused in the app instead of stopping the game at start."""
import re
from pathlib import Path

from . import protocol

# name -> (environment variable, description, allowed values or a checker)
GAME_SETTINGS = {
    'output_res': ('TOTK_OUTPUT_RES', 'Output size: auto (the window decides), 2560x1440 (true 2K), or 0 (the game\'s own 1080p canvas)',
                   ('auto', '2560x1440', '0')),
    'operation_mode': ('TOTK_OPERATION_MODE', 'Docked or handheld console mode', ('docked', 'handheld')),
    'hud': ('TOTK_HUD', 'Overlay layout: box (top-right) or corners', ('box', 'corners')),
    'fps_overlay': ('TOTK_FPS_OVERLAY', 'Show the FPS reading at start', ('1', '0')),
    'aspect': ('TOTK_ASPECT', 'Start in a wide shape (1.2.1 / 1.4.3): 21:9, 32:9 or <width>x<height>', 'aspect'),
    'language': ('TOTK_LANG', 'Game language code (for example en-US, ja, fr); empty follows macOS', 'language'),
    'rumble_gain': ('TOTK_RUMBLE_GAIN', 'Controller rumble strength, above 0 up to 4', 'gain'),
    'window_size': ('TOTK_WINDOW_SIZE', 'Initial window size <width>x<height>', 'window'),
}

_ASPECT = re.compile(r'^(?:(\d{1,2}):(\d{1,2})|(\d{3,5})x(\d{3,5}))$')
_LANG = re.compile(r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,4})?$')
_SIZE = re.compile(r'^(\d{3,4})x(\d{3,4})$')
BUILD_KEYS = ('repo', 'work_dir', 'output_dir', 'keys', 'firmware', 'shared_fonts')
FLAG_KEYS = ('resume_interrupted', 'watch_inputs', 'auto_rebuild')


def _check_game(name, value):
    if name not in GAME_SETTINGS:
        raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'unknown game setting {name!r}')
    if value is None or value == '':
        return None   # back to the game's default
    if not isinstance(value, str):
        value = str(value)
    _, _, rule = GAME_SETTINGS[name]
    ok = False
    if isinstance(rule, tuple):
        ok = value in rule
    elif rule == 'aspect':
        m = _ASPECT.match(value)
        ok = bool(m) and all(int(g) > 0 for g in m.groups() if g is not None)
    elif rule == 'language':
        ok = len(value) <= 7 and bool(_LANG.match(value))   # services.c: at most 7 characters
    elif rule == 'gain':
        try:
            ok = 0 < float(value) <= 4
        except ValueError:
            ok = False
    elif rule == 'window':
        m = _SIZE.match(value)
        ok = bool(m) and 320 <= int(m.group(1)) <= 8192 and 180 <= int(m.group(2)) <= 8192
    if not ok:
        raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{name}: {value!r} is not allowed ({GAME_SETTINGS[name][1]})')
    return value


def validate(values):
    """The subset of settings a client may set, checked; returns the values to store."""
    if not isinstance(values, dict):
        raise protocol.ProtocolError(protocol.INVALID_PARAMS, 'settings must be an object')
    out = {}
    for key, value in values.items():
        if key in BUILD_KEYS:
            if value in (None, ''):
                out[key] = None
                continue
            if not isinstance(value, str):
                raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{key} must be a path')
            out[key] = str(Path(value).expanduser())
        elif key in FLAG_KEYS:
            if not isinstance(value, bool):
                raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{key} must be true or false')
            out[key] = value
        elif key == 'watch_interval_s':
            if not isinstance(value, int) or isinstance(value, bool) or not 30 <= value <= 86400:
                raise protocol.ProtocolError(protocol.INVALID_PARAMS, 'watch_interval_s must be 30..86400')
            out[key] = value
        elif key == 'keep_jobs':
            if not isinstance(value, int) or isinstance(value, bool) or not 5 <= value <= 1000:
                raise protocol.ProtocolError(protocol.INVALID_PARAMS, 'keep_jobs must be 5..1000')
            out[key] = value
        elif key == 'game':
            if not isinstance(value, dict):
                raise protocol.ProtocolError(protocol.INVALID_PARAMS, 'game must be an object')
            out[key] = {name: v for name, v in ((n, _check_game(n, v)) for n, v in value.items()) if v is not None}
        else:
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'unknown setting {key!r}')
    return out


def game_environment(game_settings):
    """TOTK_* variables for the launch (only the ones set; the launcher keeps its own defaults for the rest)."""
    env = {}
    for name, value in (game_settings or {}).items():
        if name not in GAME_SETTINGS or value in (None, ''):
            continue
        variable = GAME_SETTINGS[name][0]
        if name == 'hud':
            if value == 'corners':
                env[variable] = 'corners'
            continue
        env[variable] = str(value)
    return env


def describe():
    return {name: {'env': env, 'description': text, 'values': list(rule) if isinstance(rule, tuple) else None}
            for name, (env, text, rule) in GAME_SETTINGS.items()}
