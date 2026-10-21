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
    'amiibo_dump': ('TOTK_AMIIBO', 'Amiibo dump selected in the Amiibo menu (path)', 'text'),
    'amiibo_folder': ('TOTK_AMIIBO_DIR', 'Folder holding your amiibo dumps', 'text'),
    'amiibo_id': ('TOTK_AMIIBO_ID', 'Amiibo ID of the selected dump (16 hex digits)', 'text'),
    # Cheats (games/totk/runtime/game_patches.c): verified writes for the 1.0.0 build. Off unless set to 1.
    'cheat_health': ('TOTK_CHEAT_HEALTH', 'Cheat: infinite health', ('1', '0')),
    'cheat_stamina': ('TOTK_CHEAT_STAMINA', 'Cheat: infinite stamina', ('1', '0')),
    'cheat_durability': ('TOTK_CHEAT_DURABILITY', 'Cheat: infinite weapon durability', ('1', '0')),
    'cheat_battery': ('TOTK_CHEAT_BATTERY', 'Cheat: infinite battery', ('1', '0')),
    'cheat_eat': ('TOTK_CHEAT_EAT', 'Cheat: eating does not use items', ('1', '0')),
    'cheat_item10': ('TOTK_CHEAT_ITEM10', 'Cheat: picked-up items count 10x', ('1', '0')),
    'cheat_maxstamina': ('TOTK_CHEAT_MAXSTAMINA', 'Cheat: maximum stamina (3 rings)', ('1', '0')),
    'cheat_zonai': ('TOTK_CHEAT_ZONAI', 'Cheat: Zonai devices x98', ('1', '0')),
    'cheat_materials_all': ('TOTK_CHEAT_MATERIALS_ALL', 'Cheat: all materials x98', ('1', '0')),
    'cheat_food_all': ('TOTK_CHEAT_FOOD_ALL', 'Cheat: all cooked food x98', ('1', '0')),
    'cheat_jump': ('TOTK_CHEAT_JUMP', 'Cheat: jump high while holding X', ('1', '0')),
    'cheat_maxheart': ('TOTK_CHEAT_MAXHEART', 'Cheat: maximum hearts (40)', ('1', '0')),
    'cheat_heartfill': ('TOTK_CHEAT_HEARTFILL', 'Cheat: hearts always full', ('1', '0')),
    'cheat_staminafill': ('TOTK_CHEAT_STAMINAFILL', 'Cheat: stamina always full', ('1', '0')),
    'cheat_weapon': ('TOTK_CHEAT_WEAPON', 'Cheat: weapon durability max', ('1', '0')),
    'cheat_bow': ('TOTK_CHEAT_BOW', 'Cheat: bow durability max', ('1', '0')),
    'cheat_shield': ('TOTK_CHEAT_SHIELD', 'Cheat: shield durability max', ('1', '0')),
    'cheat_arrows': ('TOTK_CHEAT_ARROWS', 'Cheat: 998 arrows', ('1', '0')),
    'cheat_rupees': ('TOTK_CHEAT_RUPEES', 'Cheat: 99,999,999 rupees', ('1', '0')),
    'cheat_materials': ('TOTK_CHEAT_MATERIALS', 'Cheat: materials x98', ('1', '0')),
    'cheat_food': ('TOTK_CHEAT_FOOD', 'Cheat: cooked food x98', ('1', '0')),
    'cheat_moonjump': ('TOTK_CHEAT_MOONJUMP', 'Cheat: moon jump while holding X', ('1', '0')),
    'cheat_move2x': ('TOTK_CHEAT_MOVE2X', 'Cheat: run 2x while holding B', ('1', '0')),
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
    elif rule == 'text':
        ok = 0 < len(value) <= 4096 and '\n' not in value and '\x00' not in value
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
