"""The agent process: the state store, the job queue, the watcher and the Unix socket clients talk to.

One agent per user: it holds an exclusive lock on <home>/agent.lock while it runs. The socket is <home>/agent.sock
(MNG_AGENT_SOCKET overrides it), in a folder only the user can open, with mode 0600.
"""
import fcntl
import json
import logging
import os
import platform
import signal
import ctypes
import ctypes.util
import logging.handlers
import shutil
import socket
import subprocess
import threading
from pathlib import Path

from . import LABEL, PROTOCOL, REPO, VERSION, agent_home, detect, diagnostics, game_data, launchd, protocol, settings
from .jobs import ACTIVE, JobManager
from .mods import Mods
from .store import Store
from .watcher import Watcher

log = logging.getLogger('mng_agent')
SUN_PATH_MAX = 104   # macOS sockaddr_un


_LIBC = None


def _peer_uid(conn):
    """uid on the other end of a Unix socket (getpeereid), or None when the platform cannot tell us."""
    global _LIBC
    try:
        if _LIBC is None:
            _LIBC = ctypes.CDLL(ctypes.util.find_library('c') or '/usr/lib/libSystem.B.dylib', use_errno=True)
        uid, gid = ctypes.c_uint32(), ctypes.c_uint32()
        if _LIBC.getpeereid(conn.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            return None
        return uid.value
    except (AttributeError, OSError):
        return None


def socket_path(home=None):
    override = os.environ.get('MNG_AGENT_SOCKET')
    if override:
        return Path(override)
    return Path(home or agent_home()) / 'agent.sock'


def launch_command(path, env):
    """open(1) with the game settings; its options must come before the app (it stops at the first operand)."""
    command = ['open']
    for key, value in sorted(env.items()):
        command += ['--env', f'{key}={value}']
    return command + [str(path)]


class Client:
    def __init__(self, conn):
        self.conn = conn
        self.write_lock = threading.Lock()
        self.subscribed = False
        self.alive = True

    def send(self, obj):
        data = protocol.encode(obj)
        with self.write_lock:
            if not self.alive:
                return False
            try:
                self.conn.sendall(data)
                return True
            except OSError:
                self.alive = False
                return False


class Agent:
    def __init__(self, home=None):
        self.home = Path(home or agent_home())
        self.home.mkdir(parents=True, exist_ok=True)
        os.chmod(self.home, 0o700)
        self.lock_file = open(self.home / 'agent.lock', 'w')
        try:
            fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock_file.close()
            raise RuntimeError(f'another agent is running for {self.home}') from None
        self.lock_file.write(str(os.getpid()))
        self.lock_file.flush()
        self.store = Store(self.home / 'state.json')
        self.clients = set()
        self.clients_lock = threading.Lock()
        self.jobs = JobManager(self.store, self.home, self.broadcast)
        self.mods = Mods(self.store, self.broadcast, repo=self.store.snapshot('settings').get('repo'))
        self.watcher = Watcher(self.store, self.jobs, self.broadcast)
        self.stopped = threading.Event()
        self.sock = None
        self.methods = {
            'hello': self.hello, 'status': self.status, 'shutdown': self.shutdown,
            'detect': lambda p: detect.scan(self._list(p, 'paths'), self.store.snapshot('settings').get('keys')),
            'keys.find': lambda p: detect.find_keys(p.get('near'), self.store.snapshot('settings').get('keys')),
            'build.submit': lambda p: self.jobs.submit(p),
            'jobs.list': self.jobs_list, 'jobs.get': self.jobs_get, 'jobs.cancel': lambda p: self.jobs.cancel(self._str(p, 'id')),
            'jobs.log': lambda p: {'lines': self.jobs.log_tail(self._str(p, 'id'), self._count(p, 'tail', 200, 5000))},
            'library.list': lambda p: self.store.snapshot('library'), 'library.remove': self.library_remove,
            'library.rebuild': self.library_rebuild, 'library.check': lambda p: {'changed': self.watcher.check()},
            'library.details': self.library_details,
            'launch': self.launch,
            'settings.get': lambda p: {'settings': self.store.snapshot('settings'), 'game': settings.describe()},
            'settings.set': self.settings_set,
            'mods.list': lambda p: self.mods.list(p.get('version')),
            'mods.add': lambda p: self.mods.add(self._str(p, 'source'), self._str(p, 'version'), p.get('name'),
                                                p.get('enabled', True)),
            'mods.remove': lambda p: self.mods.remove(self._str(p, 'id')),
            'mods.enable': lambda p: self.mods.enable(self._str(p, 'id'), bool(p.get('enabled', True))),
            'mods.apply': lambda p: self.mods.apply(self._str(p, 'version')),
            'mods.import': lambda p: self.mods.import_manual(self._str(p, 'version'), p.get('name')),
            'diagnostics.report': lambda p: diagnostics.report(self.store, self.jobs, self.home),
            'diagnostics.export': lambda p: {'path': diagnostics.export(self.store, self.jobs, self.home,
                                                                        self._str(p, 'destination'))},
            'agent.install_status': lambda p: launchd.status(),
        }

    # ---- parameter helpers ----
    @staticmethod
    def _str(params, key):
        value = params.get(key)
        if not isinstance(value, str) or not value:
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{key} is required')
        return value

    @staticmethod
    def _count(params, key, default, maximum):
        value = params.get(key, default)
        if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= maximum:
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{key} must be an integer 1..{maximum}')
        return value

    @staticmethod
    def _list(params, key):
        value = params.get(key)
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{key} must be a list of paths')
        return value

    # ---- methods ----
    def hello(self, params):
        return {'agent': LABEL, 'version': VERSION, 'protocol': PROTOCOL, 'pid': os.getpid(), 'home': str(self.home),
                'repo': self.store.snapshot('settings').get('repo') or str(REPO), 'platform': platform.system()}

    def status(self, params):
        jobs = self.store.snapshot('jobs')
        active = [j for j in jobs if j['status'] in ACTIVE]
        return {'active': active, 'library': len(self.store.snapshot('library')),
                'toolchain': diagnostics.toolchain(), 'install': launchd.status(), 'disk': self._disk()}

    def _disk(self):
        """Free space on the volume a build would use; the app warns before queueing below 25 GB."""
        path = self.store.snapshot('settings').get('work_dir') or str(Path.home())
        try:
            usage = shutil.disk_usage(path)
        except OSError:
            path, usage = str(Path.home()), shutil.disk_usage(str(Path.home()))
        return {'path': path, 'free_gb': round(usage.free / 1_000_000_000, 1)}

    def jobs_list(self, params):
        limit = params.get('limit', 50)
        if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, 'limit must be a positive integer')
        return sorted(self.store.snapshot('jobs'), key=lambda j: j['created'], reverse=True)[:limit]

    def jobs_get(self, params):
        job = self.store.job(self._str(params, 'id'))
        if not job:
            raise protocol.ProtocolError(protocol.NOT_FOUND, f'no job {params.get("id")}')
        return job

    def _app(self, path):
        for app in self.store.snapshot('library'):
            if app['path'] == path:
                return app
        raise protocol.ProtocolError(protocol.NOT_FOUND, f'{path} is not in the library')

    def library_remove(self, params):
        """Forget an app (the app itself stays where it is; delete it in Finder)."""
        path = self._str(params, 'path')
        if not self.store.remove_app(path):
            raise protocol.ProtocolError(protocol.NOT_FOUND, f'{path} is not in the library')
        self.broadcast({'event': 'library'})
        return {'removed': path}

    def library_details(self, params):
        """What the game menu shows for one app; every figure is read from disk, nothing is estimated."""
        app = self._app(self._str(params, 'path'))
        bundle = Path(app['path'])
        resources = bundle / 'Contents/Resources'
        icon = resources / 'AppIcon.icns'
        seeded = None
        try:
            seeded = int(json.loads((resources / 'totk/build/shader-seed/seed-manifest.json').read_text())['shaders'])
        except (OSError, ValueError, KeyError, TypeError):
            pass
        data = game_data()

        def count(folder, pattern='*'):
            try:
                return sum(1 for p in folder.rglob(pattern) if p.is_file())
            except OSError:
                return 0
        enabled = [m for m in self.store.snapshot('mods') if m['version'] == app['version'] and m['enabled']]
        return {'path': app['path'], 'version': app['version'], 'display_version': app['display_version'],
                'platform': app['platform'], 'built': app['built'], 'stale': bool(app.get('stale')),
                'missing': not bundle.exists(), 'icon': str(icon) if icon.is_file() else None,
                'shaders_seeded': seeded, 'shader_cache_files': count(data / 'shader-cache'),
                'save_files': count(data / 'profile'), 'mods_enabled': len(enabled),
                'mods_state': self.mods.folder_state(app['version'])}

    def library_rebuild(self, params):
        app = self._app(self._str(params, 'path'))
        return self.jobs.submit(dict(app['params']))

    def launch(self, params):
        library = [a for a in self.store.snapshot('library') if a.get('platform') == 'macos']
        path = params.get('path')
        if path:
            app = self._app(path)
        elif library:
            app = max(library, key=lambda a: a['built'])
        else:
            raise protocol.ProtocolError(protocol.NOT_FOUND, 'no app has been built yet')
        if app.get('platform') != 'macos':
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, 'only the Mac app can be started from here')
        if not Path(app['path']).is_dir():
            raise protocol.ProtocolError(protocol.NOT_FOUND, f'{app["path"]} is missing; rebuild it')
        if any(j['status'] == 'running' and j['params'].get('out') == app['path'] for j in self.store.snapshot('jobs')):
            raise protocol.ProtocolError(protocol.CONFLICT, 'this app is being rebuilt; start it when the build is done')
        env = settings.game_environment(self.store.snapshot('settings').get('game'))
        command = launch_command(app['path'], env)
        if platform.system() != 'Darwin':
            raise protocol.ProtocolError(protocol.FAILED, 'starting the game needs macOS')
        r = subprocess.run(command, capture_output=True, text=True, timeout=60)
        if r.returncode:
            raise protocol.ProtocolError(protocol.FAILED, f'open failed: {(r.stderr or r.stdout).strip()}')
        return {'launched': app['path'], 'environment': env}

    def settings_set(self, params):
        values = settings.validate(params.get('values', {}))
        if 'game' in values:
            merged = dict(self.store.snapshot('settings').get('game') or {})
            for name in params['values']['game']:
                merged.pop(name, None)
            merged.update(values['game'])
            values['game'] = merged
        result = self.store.set_settings(values)
        if 'repo' in values:
            self.mods.repo = values['repo']
        self.broadcast({'event': 'settings'})
        return result

    def shutdown(self, params):
        threading.Thread(target=self.stop, daemon=True).start()
        return {'stopping': True}

    # ---- events ----
    def broadcast(self, event):
        with self.clients_lock:
            clients = [c for c in self.clients if c.subscribed]
        for client in clients:
            client.send(event)

    # ---- serving ----
    def handle(self, conn):
        client = Client(conn)
        with self.clients_lock:
            self.clients.add(client)
        try:
            for line in protocol.read_lines(conn):
                if not line.strip():
                    continue
                rid = None
                try:
                    request = protocol.decode(line)
                    rid = request.get('id')
                    rid, method, params = protocol.check_request(request)
                    if method == 'subscribe':
                        client.subscribed = True
                        client.send(protocol.response(rid, {'subscribed': True}))
                        continue
                    handler = self.methods.get(method)
                    if handler is None:
                        raise protocol.ProtocolError(protocol.UNKNOWN_METHOD, f'unknown method {method!r}')
                    client.send(protocol.response(rid, handler(params)))
                except protocol.ProtocolError as e:
                    client.send(protocol.error(rid, e.code, e.message))
                except Exception as e:   # noqa: BLE001 - one bad request must not end the connection
                    log.exception('request failed')
                    client.send(protocol.error(rid, protocol.INTERNAL, f'{type(e).__name__}: {e}'))
        except protocol.ProtocolError as e:
            client.send(protocol.error(None, e.code, e.message))
        except OSError:
            pass
        finally:
            client.alive = False
            with self.clients_lock:
                self.clients.discard(client)
            try:
                conn.close()
            except OSError:
                pass

    def serve(self):
        path = socket_path(self.home)
        if len(str(path.with_name(f'.{path.name}.{os.getpid()}')).encode()) >= SUN_PATH_MAX:
            raise RuntimeError(f'socket path too long for macOS ({len(str(path))} bytes): {path}; set MNG_AGENT_SOCKET')
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            path.unlink()   # a stale socket from a previous agent (the lock above proves none is running)
        except FileNotFoundError:
            pass
        # Bind and listen under a temporary name, then rename: a client never finds a socket that refuses it.
        staging = path.with_name(f'.{path.name}.{os.getpid()}')
        try:
            staging.unlink()
        except FileNotFoundError:
            pass
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old_umask = os.umask(0o177)
        try:
            self.sock.bind(str(staging))
        finally:
            os.umask(old_umask)
        os.chmod(staging, 0o600)
        self.sock.listen(16)
        # Workers first: a client that finds the socket finds a running agent, and stop() is safe from here on.
        self.jobs.start()
        self.watcher.start()
        os.replace(staging, path)
        self.sock.settimeout(1.0)
        log.info('agent %s listening on %s', VERSION, path)
        while not self.stopped.is_set():
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.stopped.is_set():
                    break
                raise
            peer = _peer_uid(conn)
            if peer is not None and peer != os.getuid():
                log.warning('rejected a client from uid %s', peer)
                conn.close()
                continue
            conn.settimeout(None)
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def stop(self):
        if self.stopped.is_set():
            return
        self.stopped.set()
        self.watcher.stop()
        self.jobs.stop()
        with self.clients_lock:
            clients = list(self.clients)
        for client in clients:
            try:
                client.conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            try:
                socket_path(self.home).unlink()
            except FileNotFoundError:
                pass
        try:
            fcntl.flock(self.lock_file, fcntl.LOCK_UN)
            self.lock_file.close()
        except (OSError, ValueError):
            pass


def run(home=None):
    home = Path(home) if home else agent_home()
    home.mkdir(parents=True, exist_ok=True)
    # The log rotates here; launchd only captures startup crashes in agent.err.
    handler = logging.handlers.RotatingFileHandler(home / 'agent.log', maxBytes=5 * 1024 * 1024, backupCount=3)
    handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
    stream = logging.StreamHandler()
    stream.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
    logging.basicConfig(level=logging.INFO, handlers=[handler, stream])
    agent = Agent(home)
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda signum, frame: threading.Thread(target=agent.stop, daemon=True).start())
    try:
        agent.serve()
    finally:
        agent.stop()
    return 0
