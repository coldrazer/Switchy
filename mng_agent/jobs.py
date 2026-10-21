"""The job queue: one build at a time (a build needs the whole disk and the game slot), each in a supervised runner
process group (mng_agent/runner.py). A job that the agent was running when it stopped is resumed on the next start:
the steps it completed and that later steps verify again are skipped, the rest run again (they skip their own
finished work by hash, build_app.py)."""
import collections
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from . import REPO, detect, protocol
from .store import now

APP_NAME = 'Tears of the Kingdom'
ACTIVE = ('queued', 'running')
LOG_TAIL = 400
CANCEL_GRACE_S = 20


BUNDLE_ID = 'org.macnativegames.totk'


def ours(path):
    """True for an output this project made: an app with our bundle identifier, or an .ipa file."""
    path = Path(path)
    if path.suffix.lower() == '.ipa':
        return path.is_file()
    try:
        import plistlib
        with open(path / 'Contents/Info.plist', 'rb') as f:
            return plistlib.load(f).get('CFBundleIdentifier') == BUNDLE_ID
    except Exception:   # noqa: BLE001 - unreadable or not a plist: not ours
        return False


def fingerprint(path):
    try:
        st = Path(path).stat()
        return {'size': st.st_size, 'mtime_ns': st.st_mtime_ns}
    except (OSError, TypeError):
        return None


class JobManager:
    def __init__(self, store, home, broadcast, python=None):
        self.store, self.home, self.broadcast = store, Path(home), broadcast
        self.python = python or sys.executable
        self.jobs_dir = self.home / 'jobs'
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.wake = threading.Condition()
        self.stopping = False
        self.process = None
        self.running_id = None
        self.cancel_requested = set()
        self.logs = collections.defaultdict(lambda: collections.deque(maxlen=LOG_TAIL))
        self.thread = threading.Thread(target=self._loop, name='jobs', daemon=True)

    # ---- lifecycle ----
    def start(self):
        requeued = self.store.recover_interrupted(self.store.snapshot('settings').get('resume_interrupted', True))
        for job_id in requeued:
            self._log(job_id, 'the agent stopped during this build; resuming it')
        self.thread.start()

    def stop(self, timeout=30):
        with self.wake:
            self.stopping = True
            self.wake.notify_all()
        process = self.process
        if process and process.poll() is None:
            # Leave the job "running" in the store: the next agent start resumes it.
            self._signal(process, signal.SIGTERM)
            try:
                process.wait(timeout)
            except subprocess.TimeoutExpired:
                self._signal(process, signal.SIGKILL)
        if self.thread.ident is not None:   # stop() may come before start()
            self.thread.join(timeout)

    # ---- requests ----
    def resolve_params(self, params):
        """A build request's parameters, completed from the settings and checked; ProtocolError when unusable."""
        settings = self.store.snapshot('settings')
        game = params.get('game')
        if not isinstance(game, str) or not game:
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, 'game: the path of the base game file is required')
        game = str(Path(game).expanduser().resolve())
        info = detect.inspect_game(game)
        if not info['exists']:
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'no such file: {game}')
        if info['kind'] not in ('xci', 'nsp'):
            raise protocol.ProtocolError(protocol.INVALID_PARAMS,
                                         f'{Path(game).name}: the base game must be an XCI or NSP ({info["note"] or info["kind"]})')
        resolved = {'game': game}
        update = params.get('update')
        if update:
            update = str(Path(update).expanduser().resolve())
            u = detect.inspect_game(update)
            if not u['exists'] or u['kind'] not in ('nsp', 'nsz'):
                raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{update}: the update must be an NSP or NSZ file')
            resolved['update'] = update
        keys = params.get('keys') or settings.get('keys')
        if not keys:
            keys = detect.find_keys(game)['keys']
        if not keys:
            raise protocol.ProtocolError(protocol.INVALID_PARAMS,
                                         'no prod.keys found: choose your keys file (Settings > Keys) or drop it with the game')
        keys = str(Path(keys).expanduser().resolve())
        if not detect.check_keys(keys)['ok']:
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, f'{keys} is not a usable keys file')
        resolved['keys'] = keys
        platform = params.get('platform') or 'macos'
        if platform not in ('macos', 'ios'):
            raise protocol.ProtocolError(protocol.INVALID_PARAMS, 'platform must be macos or ios')
        resolved['platform'] = platform
        out = params.get('out')
        if not out and settings.get('output_dir'):
            out = str(Path(settings['output_dir']) / (APP_NAME + ('.ipa' if platform == 'ios' else '.app')))
        if not out:
            out = str(Path(game).parent / (APP_NAME + ('.ipa' if platform == 'ios' else '.app')))
        out_path = Path(out).expanduser().resolve()
        if out_path.suffix.lower() != ('.ipa' if platform == 'ios' else '.app'):
            raise protocol.ProtocolError(protocol.INVALID_PARAMS,
                                         f'the output must end in {".ipa" if platform == "ios" else ".app"}: {out_path}')
        if out_path.exists() and not ours(out_path):
            # The build replaces the output whole (build_app.step_app removes it first): never something else.
            raise protocol.ProtocolError(protocol.CONFLICT, f'{out_path} exists and is not an app this project built; '
                                                            'choose another output folder')
        resolved['out'] = str(out_path)
        work = params.get('work') or settings.get('work_dir')
        if work:
            resolved['work'] = str(Path(work).expanduser().resolve())
        for key in ('firmware', 'shared_fonts'):
            value = params.get(key) or settings.get(key)
            if value:
                resolved[key] = str(Path(value).expanduser().resolve())
        if params.get('no_shader_reminder'):
            resolved['no_shader_reminder'] = True
        return resolved

    def submit(self, params):
        resolved = self.resolve_params(params)
        for job in self.store.snapshot('jobs'):
            if job['status'] in ACTIVE and job['params'].get('out') == resolved['out']:
                raise protocol.ProtocolError(protocol.CONFLICT, f'a build of {resolved["out"]} is already {job["status"]} '
                                                                f'(job {job["id"]})')
        job = self.store.add_job('build', resolved, [])
        self._publish(job)
        with self.wake:
            self.wake.notify_all()
        return job

    def cancel(self, job_id):
        job = self.store.job(job_id)
        if not job:
            raise protocol.ProtocolError(protocol.NOT_FOUND, f'no job {job_id}')
        if job['status'] == 'queued':
            job = self.store.update_job(job_id, status='cancelled', finished=now(), error='cancelled before it started')
            self._publish(job)
            return job
        if job['status'] != 'running':
            raise protocol.ProtocolError(protocol.CONFLICT, f'job {job_id} is {job["status"]}')
        self.cancel_requested.add(job_id)
        process = self.process
        if process and self.running_id == job_id and process.poll() is None:
            self._signal(process, signal.SIGTERM)
            threading.Thread(target=self._kill_later, args=(process,), daemon=True).start()
        return self.store.job(job_id)

    def log_tail(self, job_id, lines=200):
        path = self.jobs_dir / f'{job_id}.log'
        if job_id in self.logs and self.logs[job_id]:
            return list(self.logs[job_id])[-lines:]
        try:
            with open(path, 'rb') as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 256 * 1024))
                return f.read().decode('utf-8', 'replace').splitlines()[-lines:]
        except OSError:
            return []

    # ---- worker ----
    def _next(self):
        queued = [j for j in self.store.snapshot('jobs') if j['status'] == 'queued']
        return min(queued, key=lambda j: j['created']) if queued else None

    def _loop(self):
        while True:
            with self.wake:
                while not self.stopping and self._next() is None:
                    self.wake.wait(5)
                if self.stopping:
                    return
            job = self._next()
            if job:
                try:
                    self._run(job)
                except Exception as e:   # noqa: BLE001 - the queue must keep going
                    self._finish(job['id'], 'failed', f'agent error: {e}')

    def _run(self, job):
        job_id = job['id']
        completed = [s['name'] for s in job['steps'] if s['status'] in ('done', 'resumed')]
        spec = self.jobs_dir / f'{job_id}.spec.json'
        settings = self.store.snapshot('settings')
        spec.write_text(json.dumps({'job': job_id, 'params': job['params'], 'completed': completed,
                                    'repo': settings.get('repo') or str(REPO)}))
        job = self.store.update_job(job_id, status='running', started=job['started'] or now(), error=None)
        self._publish(job)
        env = dict(os.environ, PYTHONPATH=os.pathsep.join(filter(None, [str(REPO), os.environ.get('PYTHONPATH')])),
                   PYTHONUNBUFFERED='1')
        with open(self.jobs_dir / f'{job_id}.log', 'ab') as log:
            log.write(f'\n==== attempt {job.get("attempt", 1)} at {time.strftime("%Y-%m-%d %H:%M:%S")} ====\n'.encode())
            log.flush()
            self.process = subprocess.Popen([self.python, '-m', 'mng_agent.runner', str(spec)], cwd=str(REPO), env=env,
                                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log,
                                            start_new_session=True)
            self.running_id = job_id
            state = {'result': None, 'error': None, 'kind': None}
            try:
                for raw in self.process.stdout:
                    try:
                        event = json.loads(raw)
                    except ValueError:
                        continue
                    self._handle(job_id, event, state)
            finally:
                code = self.process.wait()
                self.process.stdout.close()
                self.running_id = None
        if self.stopping and code != 0 and job_id not in self.cancel_requested:
            return   # stays "running": resumed at the next start
        if job_id in self.cancel_requested or code == 130 or state['kind'] == 'cancelled':
            self.cancel_requested.discard(job_id)
            self._finish(job_id, 'cancelled', 'cancelled')
        elif code == 0 and state['result']:
            self._finish(job_id, 'succeeded', None, state['result'])
        else:
            message = state['error'] or f'the build process ended with status {code}'
            self._finish(job_id, 'failed', message)

    def _handle(self, job_id, event, state):
        kind = event.get('type')
        if kind == 'plan':
            previous = {s['name']: s for s in (self.store.job(job_id) or {}).get('steps', [])}
            steps = []
            for s in event.get('steps', []):
                old = previous.get(s['name'], {})
                status = old.get('status') if old.get('status') in ('done', 'resumed') else 'pending'
                steps.append({'name': s['name'], 'title': s['title'], 'status': status if s.get('applies') else 'skipped',
                              'started': old.get('started'), 'finished': old.get('finished')})
            self._publish(self.store.update_job(job_id, steps=steps))
        elif kind == 'step':
            status, name = event.get('status'), event.get('name')
            fields = {'status': status}
            if status == 'running':
                fields['started'] = now()
            elif status in ('done', 'failed'):
                fields['finished'] = now()
            if event.get('error'):
                fields['error'] = event['error']
            self.store.update_step(job_id, name, **fields)
            job = self.store.update_job(job_id, current_step=name if status == 'running' else None)
            self._publish(job)
        elif kind == 'log':
            self._log(job_id, event.get('message', ''))
        elif kind == 'result':
            state['result'] = {k: event.get(k) for k in ('app', 'version', 'display_version', 'platform')}
        elif kind == 'error':
            state['error'], state['kind'] = event.get('message'), event.get('kind')

    def _finish(self, job_id, status, error, result=None):
        job = self.store.update_job(job_id, status=status, finished=now(), error=error, result=result, current_step=None)
        if status == 'succeeded' and result:
            params = job['params']
            self.store.upsert_app({
                'path': result['app'], 'version': result['version'], 'display_version': result['display_version'],
                'platform': result['platform'], 'built': now(), 'job': job_id, 'params': params,
                'inputs': {k: fingerprint(params[k]) for k in ('game', 'update') if params.get(k)},
                'stale': False, 'missing': False})
            self.broadcast({'event': 'library'})
        self._publish(job)

    # ---- helpers ----
    def _log(self, job_id, message):
        self.logs[job_id].append(message)
        self.broadcast({'event': 'job.log', 'job': job_id, 'message': message, 'time': now()})

    def _publish(self, job):
        self.broadcast({'event': 'job', 'job': job})

    @staticmethod
    def _signal(process, sig):
        try:
            os.killpg(process.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass

    def _kill_later(self, process):
        try:
            process.wait(CANCEL_GRACE_S)
        except subprocess.TimeoutExpired:
            self._signal(process, signal.SIGKILL)
