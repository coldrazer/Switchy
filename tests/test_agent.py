"""The agent (mng_agent): protocol, job queue, cancel, resume, library, settings, mods, detection, diagnostics.

Builds run the real runner subprocess over build_app's real step graph, with harmless steps
(tests/agent_fake_pipeline.py); no game data, keys or macOS needed."""
import hashlib
import json
import os
import plistlib
import shutil
import signal
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'tests'))
import build_app  # noqa: E402
from mng_agent import detect, launchd, protocol, runner, settings  # noqa: E402
from mng_agent.client import AgentClient, AgentError  # noqa: E402
from mng_agent.server import Agent  # noqa: E402
from mng_agent.store import Store  # noqa: E402

KEYS = 'header_key = ' + '00' * 32 + '\nkey_area_key_application_00 = ' + '11' * 16 + '\ntitlekek_00 = ' + '22' * 16 + '\n'


def xci(path):
    path.write_bytes(b'\0' * 0x100 + b'HEAD' + b'\0' * 0x200)
    return path


def nsp(path, names):
    strings = b''.join(n.encode() + b'\0' for n in names)
    entries = b''
    offset = 0
    for n in names:
        entries += struct.pack('<QQII', 0, 0, offset, 0)
        offset += len(n) + 1
    path.write_bytes(b'PFS0' + struct.pack('<II', len(names), len(strings)) + b'\0' * 4 + entries + strings)
    return path


def wait_for(predicate, timeout=20, interval=0.05):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    raise AssertionError('timed out')


class AgentHarness(unittest.TestCase):
    """A real agent on a private socket, with its own home, game data and fake build."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mng-')
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        self.data = self.root / 'data'
        self.env = mock.patch.dict(os.environ, {
            'MNG_AGENT_HOME': str(self.home), 'MNG_AGENT_SOCKET': str(self.root / 's.sock'),
            'MNG_GAME_DATA': str(self.data), 'MNG_GAME_LOGS': str(self.root / 'logs'),
            'MNG_AGENT_PIPELINE': 'agent_fake_pipeline:BUILD', 'MNG_FAKE': 'ok',
            'MNG_FAKE_TRACE': str(self.root / 'trace.txt'),
            'PYTHONPATH': os.pathsep.join([str(ROOT / 'tests'), str(ROOT)])})
        self.env.start()
        self.games = self.root / 'games'
        self.games.mkdir()
        self.game = xci(self.games / 'totk.xci')
        (self.games / 'prod.keys').write_text(KEYS)
        self.agents = []
        self.start_agent()

    def tearDown(self):
        for agent, thread in self.agents:
            agent.stop()
            thread.join(10)
        self.env.stop()
        self.tmp.cleanup()

    def start_agent(self):
        agent = Agent(self.home)
        thread = threading.Thread(target=agent.serve, daemon=True)
        thread.start()
        self.agents.append((agent, thread))
        wait_for(lambda: (self.root / 's.sock').exists())
        self.agent = agent
        return agent

    def stop_agent(self):
        agent, thread = self.agents.pop()
        agent.stop()
        thread.join(15)

    def client(self):
        return AgentClient(self.root / 's.sock', timeout=20)

    def wait_job(self, job_id, statuses=('succeeded', 'failed', 'cancelled'), timeout=30):
        with self.client() as c:
            return wait_for(lambda: (lambda j: j if j['status'] in statuses else None)(c.call('jobs.get', id=job_id)),
                            timeout)

    def trace(self):
        path = self.root / 'trace.txt'
        return path.read_text().split() if path.exists() else []


class Protocol(AgentHarness):
    def raw(self, payload):
        s = socket.socket(socket.AF_UNIX)
        s.connect(str(self.root / 's.sock'))
        s.settimeout(10)
        s.sendall(payload)
        data = b''
        while not data.endswith(b'\n'):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        s.close()
        return json.loads(data.splitlines()[0]) if data else None

    def test_malformed_requests_get_errors_and_the_connection_survives(self):
        self.assertEqual(self.raw(b'not json\n')['error']['code'], protocol.BAD_REQUEST)
        self.assertEqual(self.raw(b'[1,2]\n')['error']['code'], protocol.BAD_REQUEST)
        self.assertEqual(self.raw(b'{"method":"hello"}\n')['error']['code'], protocol.BAD_REQUEST)
        self.assertEqual(self.raw(b'{"id":1,"method":"nope"}\n')['error']['code'], protocol.UNKNOWN_METHOD)
        self.assertEqual(self.raw(b'{"id":1,"method":"hello","params":[]}\n')['error']['code'], protocol.INVALID_PARAMS)
        self.assertEqual(self.raw(b'{"id":"a","method":"jobs.get","params":{}}\n')['error'],
                         {'code': protocol.INVALID_PARAMS, 'message': 'id is required'})
        with self.client() as c:   # still serving
            self.assertEqual(c.call('hello')['protocol'], 1)

    def test_overlong_line_is_refused(self):
        reply = self.raw(b'{"id":1,"method":"hello","params":{"x":"' + b'a' * (protocol.MAX_LINE + 10) + b'"}}\n')
        self.assertEqual(reply['error']['code'], protocol.BAD_REQUEST)

    def test_socket_and_home_are_private(self):
        self.assertEqual(os.stat(self.root / 's.sock').st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(self.home).st_mode & 0o777, 0o700)

    def test_stop_before_serving_is_safe(self):
        with tempfile.TemporaryDirectory() as d:
            agent = Agent(Path(d))
            agent.stop()   # never served: nothing to join, no error

    def test_one_agent_per_home(self):
        with self.assertRaisesRegex(RuntimeError, 'another agent'):
            Agent(self.home)


class Builds(AgentHarness):
    def submit(self, **params):
        with self.client() as c:
            return c.call('build.submit', game=str(self.game), out=str(self.root / 'out/Tears of the Kingdom.app'),
                          **params)

    def test_successful_build_reports_steps_logs_and_lands_in_the_library(self):
        events = []
        listener = self.client()
        done = threading.Event()

        def listen():
            for e in listener.events(timeout=30):
                events.append(e)
                if e.get('event') == 'job' and e['job']['status'] == 'succeeded':
                    done.set()
                    return
        threading.Thread(target=listen, daemon=True).start()
        time.sleep(0.2)
        job = self.submit()
        self.assertEqual(job['params']['keys'], str((self.games / 'prod.keys').resolve()), 'keys found next to the game')
        self.assertTrue(done.wait(30), 'no success event')
        job = self.wait_job(job['id'])
        self.assertEqual(job['status'], 'succeeded', job)
        statuses = {s['name']: s['status'] for s in job['steps']}
        self.assertEqual(statuses['identify_update'], 'skipped')
        self.assertTrue(all(v == 'done' for k, v in statuses.items() if k != 'identify_update'), statuses)
        self.assertEqual(job['result']['version'], 'v0')
        self.assertIn('fake step data', [e['message'] for e in events if e.get('event') == 'job.log'])
        with self.client() as c:
            library = c.call('library.list')
            self.assertEqual([a['path'] for a in library], [job['params']['out']])
            self.assertEqual(library[0]['display_version'], '1.0.0')
            self.assertIn('fake step package', c.call('jobs.log', id=job['id'])['lines'])
        listener.close()

    def test_library_details_reads_real_figures(self):
        job = self.wait_job(self.submit()['id'])
        out = Path(job['params']['out'])
        seed = out / 'Contents/Resources/totk/build/shader-seed'
        seed.mkdir(parents=True)
        (seed / 'seed-manifest.json').write_text(json.dumps({'shaders': 8290}))
        (out / 'Contents/Resources/AppIcon.icns').write_bytes(b'icns')
        for rel in ('shader-cache/rt-x/a.metallib', 'shader-cache/rt-x/b.metallib', 'profile/save/0/game.sav'):
            (self.data / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.data / rel).write_bytes(b'1')
        with self.client() as c:
            d = c.call('library.details', path=str(out))
            with self.assertRaises(AgentError):
                c.call('library.details', path='/nowhere.app')
        self.assertEqual((d['shaders_seeded'], d['shader_cache_files'], d['save_files'], d['mods_enabled']), (8290, 2, 1, 0))
        self.assertEqual(d['icon'], str(out / 'Contents/Resources/AppIcon.icns'))
        self.assertEqual(d['mods_state'], 'none')

    def test_failed_build_names_the_step_and_error(self):
        os.environ['MNG_FAKE'] = 'fail:data'
        job = self.wait_job(self.submit()['id'])
        self.assertEqual(job['status'], 'failed')
        self.assertEqual(job['error'], 'fake failure in data')
        step = next(s for s in job['steps'] if s['name'] == 'data')
        self.assertEqual((step['status'], step['error']), ('failed', 'fake failure in data'))
        with self.client() as c:
            self.assertEqual(c.call('library.list'), [])

    def test_submit_validation(self):
        with self.client() as c:
            for params, message in [({}, 'game'), ({'game': str(self.root / 'none.xci')}, 'no such file'),
                                    ({'game': str(self.games / 'prod.keys')}, 'XCI or NSP'),
                                    ({'game': str(self.game), 'platform': 'linux'}, 'platform')]:
                with self.subTest(params=params), self.assertRaises(AgentError) as e:
                    c.call('build.submit', **params)
                self.assertEqual(e.exception.code, protocol.INVALID_PARAMS)
                self.assertIn(message, e.exception.message)
            (self.games / 'prod.keys').unlink()
            with mock.patch.object(detect, 'key_candidates', return_value=[]), self.assertRaises(AgentError) as e:
                c.call('build.submit', game=str(self.game))
            self.assertIn('no prod.keys', e.exception.message)

    def test_duplicate_build_of_the_same_app_is_refused(self):
        os.environ['MNG_FAKE'] = 'slow:0.5'
        job = self.submit()
        with self.assertRaises(AgentError) as e:
            self.submit()
        self.assertEqual(e.exception.code, protocol.CONFLICT)
        self.wait_job(job['id'])

    def test_queue_runs_jobs_one_at_a_time_in_order(self):
        os.environ['MNG_FAKE'] = 'slow:0.05'
        with self.client() as c:
            a = c.call('build.submit', game=str(self.game), out=str(self.root / 'a/Tears of the Kingdom.app'))
            b = c.call('build.submit', game=str(self.game), out=str(self.root / 'b/Tears of the Kingdom.app'))
        a, b = self.wait_job(a['id']), self.wait_job(b['id'])
        self.assertEqual((a['status'], b['status']), ('succeeded', 'succeeded'))
        self.assertLessEqual(a['finished'], b['started'])

    def test_cancel_stops_the_whole_process_group(self):
        os.environ.update(MNG_FAKE='spawn', MNG_FAKE_CHILD=str(self.root / 'child.pid'))
        job = self.submit()
        pid = int(wait_for(lambda: (self.root / 'child.pid').exists() and (self.root / 'child.pid').read_text()))
        with self.client() as c:
            c.call('jobs.cancel', id=job['id'])
        job = self.wait_job(job['id'])
        self.assertEqual(job['status'], 'cancelled')

        def gone():
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            try:   # a zombie of the killed group counts as gone
                with open(f'/proc/{pid}/stat') as f:
                    return f.read().split()[2] == 'Z'
            except OSError:
                return True
            return False
        wait_for(gone, 10)

    def test_never_overwrites_an_app_it_did_not_build(self):
        other = self.root / 'Applications/Other.app'
        (other / 'Contents').mkdir(parents=True)
        (other / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.example.other'}))
        with self.client() as c:
            with self.assertRaises(AgentError) as e:
                c.call('build.submit', game=str(self.game), out=str(other))
            self.assertEqual(e.exception.code, protocol.CONFLICT)
            with self.assertRaises(AgentError) as e:
                c.call('build.submit', game=str(self.game), out=str(self.root / 'x/Game.zip'))
            self.assertEqual(e.exception.code, protocol.INVALID_PARAMS)
            with self.assertRaises(AgentError) as e:
                c.call('jobs.log', id='x', tail='lots')
            self.assertEqual(e.exception.code, protocol.INVALID_PARAMS)
        self.assertTrue((other / 'Contents/Info.plist').exists())
        # Our own earlier build may be replaced.
        first = self.wait_job(self.submit()['id'])
        self.assertEqual(self.wait_job(self.submit()['id'])['status'], 'succeeded', first)

    def test_auto_rebuild_happens_once_per_change_even_when_it_fails(self):
        self.wait_job(self.submit()['id'])
        os.environ['MNG_FAKE'] = 'fail:data'
        with self.client() as c:
            c.call('settings.set', values={'auto_rebuild': True})
            os.utime(self.game, ns=(1, 1))
            c.call('library.check')
            failed = c.call('jobs.list')[0]
            self.assertEqual(self.wait_job(failed['id'])['status'], 'failed')
            c.call('library.check')
            c.call('library.check')
            self.assertEqual(len(c.call('jobs.list')), 2, 'a failed automatic rebuild is not retried')
            os.utime(self.game, ns=(2, 2))
            c.call('library.check')
            self.assertEqual(len(c.call('jobs.list')), 3, 'a new change gets a new attempt')
            self.wait_job(c.call('jobs.list')[0]['id'])

    def test_cancel_a_queued_job(self):
        os.environ['MNG_FAKE'] = 'slow:0.3'
        with self.client() as c:
            first = c.call('build.submit', game=str(self.game), out=str(self.root / 'a/Tears of the Kingdom.app'))
            second = c.call('build.submit', game=str(self.game), out=str(self.root / 'b/Tears of the Kingdom.app'))
            self.assertEqual(c.call('jobs.cancel', id=second['id'])['status'], 'cancelled')
            with self.assertRaises(AgentError) as e:
                c.call('jobs.cancel', id='nope')
            self.assertEqual(e.exception.code, protocol.NOT_FOUND)
        self.assertEqual(self.wait_job(first['id'])['status'], 'succeeded')
        self.assertEqual(self.wait_job(second['id'])['status'], 'cancelled')

    def test_a_build_interrupted_by_an_agent_restart_resumes(self):
        os.environ['MNG_FAKE'] = 'slow:0.4'
        job = self.submit()
        self.wait_job(job['id'], statuses=('running',))
        wait_for(lambda: 'shaders' in self.trace(), 20)
        self.stop_agent()
        self.assertEqual(Store(self.home / 'state.json').job(job['id'])['status'], 'running', 'left for the next start')
        os.environ['MNG_FAKE'] = 'ok'
        (self.root / 'trace.txt').unlink()
        self.start_agent()
        job = self.wait_job(job['id'])
        self.assertEqual(job['status'], 'succeeded', job)
        self.assertEqual(job['attempt'], 2)
        executed = self.trace()
        # code and data finished before the stop and are verified again later: skipped. The rest ran again.
        self.assertNotIn('code', executed)
        self.assertNotIn('data', executed)
        self.assertIn('prerequisites', executed)
        self.assertIn('package', executed)
        statuses = {s['name']: s['status'] for s in job['steps']}
        self.assertEqual(statuses['code'], 'resumed')

    def test_watcher_marks_changed_inputs_and_missing_apps(self):
        job = self.wait_job(self.submit()['id'])
        with self.client() as c:
            self.assertEqual(c.call('library.check')['changed'], [])
            os.utime(self.game, ns=(1, 1))
            self.assertEqual(c.call('library.check')['changed'], [job['params']['out']])
            self.assertTrue(c.call('library.list')[0]['stale'])
            shutil.rmtree(job['params']['out'])
            c.call('library.check')
            self.assertTrue(c.call('library.list')[0]['missing'])
            with self.assertRaises(AgentError) as e:
                c.call('launch')
            self.assertEqual(e.exception.code, protocol.NOT_FOUND)
            rebuilt = c.call('library.rebuild', path=job['params']['out'])
        self.assertEqual(self.wait_job(rebuilt['id'])['status'], 'succeeded')

    def test_auto_rebuild_queues_a_build_for_a_changed_game(self):
        job = self.wait_job(self.submit()['id'])
        with self.client() as c:
            c.call('settings.set', values={'auto_rebuild': True})
            os.utime(self.game, ns=(1, 1))
            c.call('library.check')
            jobs = c.call('jobs.list')
        self.assertEqual(len(jobs), 2)
        self.assertEqual(jobs[0]['params']['game'], job['params']['game'])
        self.wait_job(jobs[0]['id'])

    def test_diagnostics_export_never_contains_keys(self):
        self.wait_job(self.submit()['id'])
        with self.client() as c:
            c.call('settings.set', values={'keys': str(self.games / 'prod.keys')})
            report = c.call('diagnostics.report')
            self.assertEqual(report['settings']['keys'], 'set')
            path = c.call('diagnostics.export', destination=str(self.root / 'diag.zip'))['path']
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            self.assertIn('report.json', names)
            self.assertTrue(any(n.startswith('jobs/') for n in names))
            blob = b''.join(z.read(n) for n in names)
        self.assertNotIn(b'22' * 16, blob)
        self.assertNotIn(b'header_key', blob)


class SettingsAndLaunch(AgentHarness):
    def test_settings_are_validated_like_the_runtime(self):
        with self.client() as c:
            s = c.call('settings.set', values={'auto_rebuild': True, 'game': {'output_res': '2560x1440',
                                                                              'operation_mode': 'handheld',
                                                                              'rumble_gain': '1.5', 'aspect': '21:9'}})
            self.assertTrue(s['auto_rebuild'])
            self.assertEqual(s['game']['output_res'], '2560x1440')
            # Clearing one game setting keeps the others.
            s = c.call('settings.set', values={'game': {'aspect': None}})
            self.assertNotIn('aspect', s['game'])
            self.assertEqual(s['game']['operation_mode'], 'handheld')
            for values in [{'auto_rebuild': 'yes'}, {'nope': 1}, {'game': {'output_res': '1234x567'}},
                           {'game': {'operation_mode': 'tabletop'}}, {'game': {'rumble_gain': '5'}},
                           {'game': {'rumble_gain': '0'}}, {'game': {'language': 'english-us'}},
                           {'game': {'aspect': '0:9'}}, {'game': {'window_size': '100x100'}}, {'game': {'x': '1'}},
                           {'watch_interval_s': 5}]:
                with self.subTest(values=values), self.assertRaises(AgentError) as e:
                    c.call('settings.set', values=values)
                self.assertEqual(e.exception.code, protocol.INVALID_PARAMS)
            described = c.call('settings.get')['game']
            self.assertEqual(described['operation_mode']['env'], 'TOTK_OPERATION_MODE')

    def test_game_environment(self):
        self.assertEqual(settings.game_environment({'hud': 'box', 'output_res': '0', 'language': 'ja'}),
                         {'TOTK_OUTPUT_RES': '0', 'TOTK_LANG': 'ja'})
        self.assertEqual(settings.game_environment({'hud': 'corners'}), {'TOTK_HUD': 'corners'})

    def test_launch_command_puts_options_before_the_app(self):
        from mng_agent.server import launch_command
        self.assertEqual(launch_command('/A/T.app', {'TOTK_LANG': 'ja', 'TOTK_HUD': 'corners'}),
                         ['open', '--env', 'TOTK_HUD=corners', '--env', 'TOTK_LANG=ja', '/A/T.app'])

    def test_launch_needs_a_built_app(self):
        with self.client() as c, self.assertRaises(AgentError) as e:
            c.call('launch')
        self.assertEqual(e.exception.code, protocol.NOT_FOUND)


def fake_app_romfs(app, version, files):
    """A built app's RomFS (romfs.bin + runtime-index.bin) for mod manifests."""
    folder = app / f'Contents/Resources/totk/extracted/{version}/romfs'
    folder.mkdir(parents=True)
    image, rows, strings = bytearray(), bytearray(), bytearray()
    for path in sorted(files):
        name = path.encode() + b'\0'
        rows += struct.pack('<QQII', len(image), len(files[path]), len(strings), len(name))
        image += files[path]
        strings += name
    (folder / 'romfs.bin').write_bytes(image)
    (folder / 'runtime-index.bin').write_bytes(struct.pack('<8sQQ', b'TOTKRFS1', len(files), 24 + len(rows)) + rows + strings)


class Mods(AgentHarness):
    ORIGINAL = {'Pack/A.pack.zs': b'original a', 'Sound/B.bwav': b'original b', 'UI/C.bfres': b'c'}

    def setUp(self):
        super().setUp()
        app = self.root / 'built/Tears of the Kingdom.app'
        fake_app_romfs(app, 'v143', self.ORIGINAL)
        self.agent.store.upsert_app({'path': str(app), 'version': 'v143', 'display_version': '1.4.3', 'platform': 'macos',
                                     'built': time.time(), 'params': {'game': str(self.game)}, 'inputs': {}})

    def mod(self, name, files):
        folder = self.root / 'src' / name
        for rel, data in files.items():
            (folder / rel).parent.mkdir(parents=True, exist_ok=True)
            (folder / rel).write_bytes(data)
        return folder

    def manifest(self):
        return (self.data / 'mods/v143/manifest.tsv').read_text().splitlines()[1:]

    def test_compose_conflict_disable_and_remove(self):
        with self.client() as c:
            a = c.call('mods.add', source=str(self.mod('voices', {'Sound/B.bwav': b'new voice'})), version='v143')
            self.assertEqual(a['apply']['files'], 1)
            b = c.call('mods.add', source=str(self.mod('extra', {'New/D.txt': b'added', '.DS_Store': b'x'})),
                       version='v143', name='Extra content')
            self.assertEqual(b['apply'], {'version': 'v143', 'mods': 2, 'files': 2, 'added': 1, 'unchanged': 0})
            lines = self.manifest()
            self.assertIn(f'New/D.txt\t5\t{hashlib.sha256(b"added").hexdigest()}\t-', lines)
            self.assertIn(f'Sound/B.bwav\t9\t{hashlib.sha256(b"new voice").hexdigest()}\t'
                          f'{hashlib.sha256(b"original b").hexdigest()}', lines)
            self.assertFalse((self.data / 'mods/v143/.DS_Store').exists())
            # A third mod that changes the same file as the first is kept but not enabled.
            clash = c.call('mods.add', source=str(self.mod('clash', {'Sound/B.bwav': b'other voice'})), version='v143')
            self.assertFalse(clash['mod']['enabled'])
            self.assertIn('both change Sound/B.bwav', clash['apply_error'])
            self.assertEqual(len(self.manifest()), 2, 'the active folder is unchanged')
            with self.assertRaises(AgentError) as e:
                c.call('mods.enable', id=clash['mod']['id'], enabled=True)
            self.assertEqual(e.exception.code, protocol.CONFLICT)
            self.assertFalse(next(m for m in c.call('mods.list')['mods'] if m['id'] == clash['mod']['id'])['enabled'])
            # Disable the first; then the clash fits.
            c.call('mods.enable', id=a['mod']['id'], enabled=False)
            c.call('mods.enable', id=clash['mod']['id'], enabled=True)
            self.assertIn(f'Sound/B.bwav\t11\t{hashlib.sha256(b"other voice").hexdigest()}\t'
                          f'{hashlib.sha256(b"original b").hexdigest()}', self.manifest())
            for mod in c.call('mods.list')['mods']:
                c.call('mods.remove', id=mod['id'])
            self.assertFalse((self.data / 'mods/v143').exists(), 'no enabled mods: no folder')
            self.assertEqual(list((self.data / 'mod-library').iterdir()), [])

    def test_hand_made_folder_is_never_overwritten_until_imported(self):
        manual = self.data / 'mods/v143'
        manual.mkdir(parents=True)
        (manual / 'UI').mkdir()
        (manual / 'UI/C.bfres').write_bytes(b'hand made')
        (manual / 'manifest.tsv').write_text('# hand made\n')
        with self.client() as c:
            self.assertEqual(c.call('mods.list', version='v143')['folders']['v143']['state'], 'manual')
            r = c.call('mods.add', source=str(self.mod('voices', {'Sound/B.bwav': b'v'})), version='v143')
            self.assertIn('hand-made', r['apply_error'])
            self.assertEqual((manual / 'manifest.tsv').read_text(), '# hand made\n')
            imported = c.call('mods.import', version='v143')
            self.assertEqual(imported['apply']['files'], 1)
            c.call('mods.enable', id=r['mod']['id'], enabled=True)
            self.assertEqual(len(self.manifest()), 2)
            self.assertEqual(c.call('mods.list', version='v143')['folders']['v143']['state'], 'composed')

    def test_misspelt_paths_and_unknown_versions_are_refused(self):
        with self.client() as c:
            r = c.call('mods.add', source=str(self.mod('typo', {'sound/b.bwav': b'v'})), version='v143')
            self.assertIn('case-sensitive', r['apply_error'])
            with self.assertRaises(AgentError):
                c.call('mods.add', source=str(self.mod('old', {'X': b'1'})), version='v999')
            r = c.call('mods.add', source=str(self.mod('v0mod2', {'X': b'1'})), version='v0')
            self.assertIn('no built app for game version v0', r['apply_error'])


class Units(unittest.TestCase):
    def test_build_graph_is_ordered_and_checked(self):
        names = [s.name for s in build_app.ordered()]
        self.assertEqual(names[0], 'prerequisites')
        self.assertLess(names.index('manifest'), names.index('shaders'))
        self.assertLess(names.index('update_data'), names.index('manifest'))
        self.assertEqual(names[-1], 'warm_metal')
        S = build_app.Step
        with self.assertRaisesRegex(ValueError, 'cycle'):
            build_app.ordered([S('a', '', None, needs=('b',)), S('b', '', None, needs=('a',))])
        with self.assertRaisesRegex(ValueError, 'unknown'):
            build_app.ordered([S('a', '', None, needs=('z',))])
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            build_app.ordered([S('a', '', None), S('a', '', None)])

    def test_run_pipeline_skips_only_resumable_completed_steps(self):
        ran, seen = [], []
        S = build_app.Step
        steps = [S('a', '', lambda c: ran.append('a')), S('b', '', lambda c: ran.append('b'), resumable=True),
                 S('c', '', lambda c: ran.append('c'), when=lambda c: False)]
        c = build_app.Context(t0=time.time(), out='x')
        with mock.patch.object(build_app, 'say'):
            build_app.run_pipeline(c, steps, completed={'a', 'b'}, on_step=lambda s, st, e=None: seen.append((s.name, st)))
        self.assertEqual(ran, ['a'])
        self.assertEqual(seen, [('a', 'running'), ('a', 'done'), ('b', 'resumed'), ('c', 'skipped')])

    def test_runner_arguments(self):
        self.assertEqual(runner.arguments({'game': '/g.xci', 'keys': '/k', 'platform': 'ios', 'update': '/u.nsp',
                                           'out': '/o.ipa', 'shared_fonts': '/f', 'no_shader_reminder': True}),
                         ['/g.xci', '--keys', '/k', '--platform', 'ios', '--update', '/u.nsp', '--out', '/o.ipa',
                          '--shared-fonts', '/f', '--no-shader-reminder'])
        args = build_app.parse_args(runner.arguments({'game': '/g.xci', 'keys': '/k', 'firmware': '/fw'}))
        self.assertEqual((str(args.game), str(args.firmware), args.platform), ('/g.xci', '/fw', 'macos'))

    def test_detect_classifies_files_by_content(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            self.assertEqual(detect.inspect_game(xci(d / 'a.bin'))['kind'], 'xci')
            base = detect.inspect_game(nsp(d / 'b.nsp', ['0100f2c0115b60000000000000000004.tik', 'x.nca']))
            self.assertEqual((base['kind'], base['role']), ('nsp', 'base'))
            update = detect.inspect_game(nsp(d / 'renamed-base.nsp', ['0100F2C0115B68000000000000000004.tik']))
            self.assertEqual(update['role'], 'update', 'the ticket name decides, not the file name')
            self.assertEqual(detect.inspect_game(nsp(d / 'c.nsz', ['y.ncz']))['role'], 'update')
            (d / 'junk.xci').write_bytes(b'nothing here')
            self.assertIsNone(detect.inspect_game(d / 'junk.xci')['kind'])
            self.assertFalse(detect.inspect_game(d / 'missing.xci')['exists'])
            (d / 'prod.keys').write_text(KEYS)
            (d / 'partial.keys').write_text('header_key = 00\n')
            good, partial = detect.check_keys(d / 'prod.keys'), detect.check_keys(d / 'partial.keys')
            self.assertTrue(good['ok'])
            self.assertEqual(partial['missing'], ['key_area_key_application_*', 'titlekek_*'])
            self.assertNotIn('22' * 16, json.dumps([good, partial]), 'key values are never returned')
            scan = detect.scan([str(d / 'b.nsp'), str(d / 'renamed-base.nsp'), str(d / 'prod.keys')])
            self.assertEqual((Path(scan['base']).name, Path(scan['update']).name, Path(scan['keys']).name),
                             ('b.nsp', 'renamed-base.nsp', 'prod.keys'))

    def test_launch_agent_plist(self):
        data = launchd.plist(python='/opt/homebrew/bin/python3.14', repo='/r', home=Path('/h'))
        self.assertEqual(data['Label'], 'com.macnativegames.agent')
        self.assertEqual(data['ProgramArguments'], ['/opt/homebrew/bin/python3.14', '-m', 'mng_agent', 'serve'])
        self.assertEqual(data['KeepAlive'], {'SuccessfulExit': False})
        self.assertEqual(data['EnvironmentVariables']['PYTHONPATH'], '/r')
        plistlib.dumps(data)   # serialisable

    def test_store_survives_a_corrupt_file_and_refuses_a_newer_schema(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'state.json'
            path.write_text('{broken')
            store = Store(path)
            self.assertIn('broken', store.data['recovered_from'])
            self.assertEqual(store.snapshot('jobs'), [])
            path.write_text(json.dumps({'schema': 99}))
            with self.assertRaisesRegex(Exception, 'schema 99'):
                Store(path)


if __name__ == '__main__':
    unittest.main()


class ServerPeerTests(unittest.TestCase):
    def test_peer_uid_is_this_user(self):
        from mng_agent.server import _peer_uid
        left, right = socket.socketpair()
        try:
            self.assertEqual(_peer_uid(left), os.getuid())
        finally:
            left.close()
            right.close()
