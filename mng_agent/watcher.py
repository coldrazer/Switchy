"""Continuity: notice when a built app's game files change or the app goes missing, and optionally rebuild."""
import threading
from pathlib import Path

from .jobs import ACTIVE, fingerprint


class Watcher:
    def __init__(self, store, jobs, broadcast):
        self.store, self.jobs, self.broadcast = store, jobs, broadcast
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._loop, name='watcher', daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()

    def _loop(self):
        while not self.stop_event.wait(max(30, int(self.store.snapshot('settings').get('watch_interval_s') or 300))):
            try:
                self.check()
            except Exception:   # noqa: BLE001 - a watcher error must not end the agent
                pass

    def check(self):
        """One pass; returns the paths whose state changed."""
        settings = self.store.snapshot('settings')
        if not settings.get('watch_inputs', True):
            return []
        changed = []
        active_outs = {j['params'].get('out') for j in self.store.snapshot('jobs') if j['status'] in ACTIVE}
        for app in self.store.snapshot('library'):
            missing = not Path(app['path']).exists()
            stale = any(fingerprint(app['params'].get(k)) != fp for k, fp in (app.get('inputs') or {}).items())
            if missing != app.get('missing') or stale != app.get('stale'):
                self.store.set_app_fields(app['path'], missing=missing, stale=stale)
                changed.append(app['path'])
            current = {k: fingerprint(app['params'].get(k)) for k in (app.get('inputs') or {})}
            if stale and settings.get('auto_rebuild') and app['path'] not in active_outs and \
                    app.get('auto_rebuilt_for') != current and \
                    all(Path(app['params'][k]).is_file() for k in ('game', 'update') if app['params'].get(k)):
                # Once per change of the inputs: a build that fails is not retried every pass.
                self.store.set_app_fields(app['path'], auto_rebuilt_for=current)
                try:
                    self.jobs.submit(dict(app['params']))
                except Exception:   # noqa: BLE001 - shown on the next manual rebuild instead
                    pass
        if changed:
            self.broadcast({'event': 'library'})
        return changed
