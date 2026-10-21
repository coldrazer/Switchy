"""The agent's state: jobs, the library of built apps, mods and settings, in one JSON file written atomically.

Only the agent process writes it (it holds an exclusive lock on <home>/agent.lock for its lifetime); clients read the
state through the socket. A file from a newer agent is refused rather than overwritten.
"""
import copy
import json
import os
import threading
import time
import uuid
from pathlib import Path

SCHEMA = 1

DEFAULT_SETTINGS = {
    # Build
    'repo': None,                 # MacNativeGames checkout holding build_app.py (None: the one this agent runs from)
    'work_dir': None,             # None: TOTK_build next to the game file, as build_app.py does
    'output_dir': None,           # None: next to the game file
    'keys': None,                 # prod.keys; None: found by mng_agent.detect
    'firmware': None,
    'shared_fonts': None,
    # Behaviour
    'resume_interrupted': True,   # re-queue a build the agent was running when it stopped
    'watch_inputs': True,         # notice when a built app's game files change
    'auto_rebuild': False,        # and then rebuild without asking
    'watch_interval_s': 300,
    'keep_jobs': 50,
    # Game launch (passed to the game as TOTK_* environment variables, mng_agent/settings.py)
    'game': {},
}


class StoreError(Exception):
    pass


def now():
    return round(time.time(), 3)


def new_id():
    return uuid.uuid4().hex[:12]


class Store:
    def __init__(self, path):
        self.path = Path(path)
        self.lock = threading.RLock()
        self.data = self._load()

    def _empty(self):
        return {'schema': SCHEMA, 'jobs': [], 'library': [], 'mods': [], 'settings': copy.deepcopy(DEFAULT_SETTINGS)}

    def _load(self):
        try:
            data = json.loads(self.path.read_text())
        except FileNotFoundError:
            return self._empty()
        except (OSError, ValueError) as e:
            # Keep the unreadable file for inspection and start clean rather than refuse to run.
            broken = self.path.with_name(f'{self.path.name}.broken-{int(time.time())}')
            try:
                os.replace(self.path, broken)
            except OSError:
                pass
            data = self._empty()
            data['recovered_from'] = f'{broken.name}: {e}'
            return data
        if not isinstance(data, dict) or data.get('schema') != SCHEMA:
            raise StoreError(f'{self.path} has schema {data.get("schema") if isinstance(data, dict) else "?"}; '
                             f'this agent understands {SCHEMA}')
        base = self._empty()
        base.update({k: v for k, v in data.items() if k in base or k == 'recovered_from'})
        settings = copy.deepcopy(DEFAULT_SETTINGS)
        settings.update(base.get('settings') or {})
        base['settings'] = settings
        return base

    def save(self):
        with self.lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_name(self.path.name + '.partial')
            with open(tmp, 'w') as f:
                json.dump(self.data, f, indent=1, sort_keys=True, default=str)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)

    # ---- reads (copies, so callers cannot change the store behind its lock) ----
    def snapshot(self, key):
        with self.lock:
            return copy.deepcopy(self.data[key])

    def job(self, job_id):
        with self.lock:
            for job in self.data['jobs']:
                if job['id'] == job_id:
                    return copy.deepcopy(job)
        return None

    # ---- jobs ----
    def add_job(self, kind, params, steps):
        job = {'id': new_id(), 'kind': kind, 'params': params, 'status': 'queued', 'created': now(), 'started': None,
               'finished': None, 'attempt': 1, 'current_step': None, 'error': None, 'result': None,
               'steps': [{'name': n, 'title': t, 'status': 'pending', 'started': None, 'finished': None}
                         for n, t in steps]}
        with self.lock:
            self.data['jobs'].append(job)
            self._prune()
            self.save()
        return copy.deepcopy(job)

    def update_job(self, job_id, **fields):
        with self.lock:
            for job in self.data['jobs']:
                if job['id'] == job_id:
                    job.update(fields)
                    self.save()
                    return copy.deepcopy(job)
        raise StoreError(f'no job {job_id}')

    def update_step(self, job_id, name, **fields):
        with self.lock:
            for job in self.data['jobs']:
                if job['id'] != job_id:
                    continue
                for step in job['steps']:
                    if step['name'] == name:
                        step.update(fields)
                        break
                else:
                    job['steps'].append(dict({'name': name, 'title': name, 'status': 'pending', 'started': None,
                                              'finished': None}, **fields))
                self.save()
                return copy.deepcopy(job)
        raise StoreError(f'no job {job_id}')

    def _prune(self):
        keep = int(self.data['settings'].get('keep_jobs') or 50)
        finished = [j for j in self.data['jobs'] if j['status'] in ('succeeded', 'failed', 'cancelled')]
        extra = len(finished) - keep
        if extra > 0:
            drop = {j['id'] for j in sorted(finished, key=lambda j: j['created'])[:extra]}
            self.data['jobs'] = [j for j in self.data['jobs'] if j['id'] not in drop]

    def recover_interrupted(self, requeue):
        """After a restart: a job the previous agent was running is interrupted. Returns the ids re-queued."""
        ids = []
        with self.lock:
            for job in self.data['jobs']:
                if job['status'] == 'running':
                    for step in job['steps']:
                        if step['status'] == 'running':
                            step['status'] = 'interrupted'
                    if requeue:
                        job.update(status='queued', attempt=job.get('attempt', 1) + 1, error=None)
                        ids.append(job['id'])
                    else:
                        job.update(status='failed', finished=now(), error='the agent stopped during this build')
            self.save()
        return ids

    # ---- library ----
    def upsert_app(self, entry):
        with self.lock:
            self.data['library'] = [a for a in self.data['library'] if a['path'] != entry['path']]
            self.data['library'].append(entry)
            self.save()

    def remove_app(self, path):
        with self.lock:
            before = len(self.data['library'])
            self.data['library'] = [a for a in self.data['library'] if a['path'] != path]
            self.save()
            return len(self.data['library']) != before

    def set_app_fields(self, path, **fields):
        with self.lock:
            for app in self.data['library']:
                if app['path'] == path:
                    app.update(fields)
                    self.save()
                    return copy.deepcopy(app)
        return None

    # ---- settings / mods ----
    def set_settings(self, values):
        with self.lock:
            self.data['settings'].update(values)
            self.save()
            return copy.deepcopy(self.data['settings'])

    def set_mods(self, mods):
        with self.lock:
            self.data['mods'] = mods
            self.save()
