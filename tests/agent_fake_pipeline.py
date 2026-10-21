"""A stand-in for build_app.py in the agent tests (MNG_AGENT_PIPELINE=agent_fake_pipeline:BUILD).

It uses build_app's real graph machinery (Step, ordered, run_pipeline) with steps that only write files, so the agent's
queue, events, cancel and resume are exercised without a game. MNG_FAKE controls it:
    ok | fail:<step> | slow:<seconds per step> | spawn (a long-lived grandchild, for cancel)
MNG_FAKE_TRACE names a file each executed step appends its name to.
"""
import os
import subprocess
import sys
import time
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import build_app  # noqa: E402

mode = os.environ.get('MNG_FAKE', 'ok')


def _step(name):
    def action(c):
        build_app.say(f'fake step {name}')
        trace = os.environ.get('MNG_FAKE_TRACE')
        if trace:
            with open(trace, 'a') as f:
                f.write(name + '\n')
        if mode.startswith('slow:'):
            time.sleep(float(mode.split(':', 1)[1]))
        if mode == 'spawn' and name == 'data':
            child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(600)'])
            Path(os.environ['MNG_FAKE_CHILD']).write_text(str(child.pid))
            time.sleep(600)
        if mode == f'fail:{name}':
            raise build_app.BuildError(f'fake failure in {name}')
        if name == 'package':
            (c.out / 'Contents').mkdir(parents=True, exist_ok=True)
            import plistlib
            (c.out / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': build_app.BUNDLE_ID}))
    return action


S = build_app.Step
STEPS = (
    S('prerequisites', 'Checking the build tools', _step('prerequisites')),
    S('work', 'Preparing the work folder', _step('work'), needs=('prerequisites',)),
    S('identify_update', 'Identifying the update', _step('identify_update'), needs=('work',), when=lambda c: c.update),
    S('code', 'Rewriting the game code', _step('code'), needs=('work',), resumable=True),
    S('data', 'Extracting and verifying the game data', _step('data'), needs=('code',), resumable=True),
    S('shaders', 'Translating the startup shaders', _step('shaders'), needs=('data',), resumable=True),
    S('binary', 'Building the game binary', _step('binary'), needs=('shaders',)),
    S('package', 'Assembling the app', _step('package'), needs=('binary',)),
)


def plan(args):
    c = build_app.plan(args)
    if c.update:
        c.version = 'v143'
    return c


class _Build(types.SimpleNamespace):
    """The runner sets BUILD.EVENT_SINK; build_app.say reads build_app.EVENT_SINK, so forward it."""

    def __setattr__(self, key, value):
        super().__setattr__(key, value)
        if key == 'EVENT_SINK':
            build_app.EVENT_SINK = value


BUILD = _Build(parse_args=build_app.parse_args, plan=plan, STEPS=STEPS, ordered=build_app.ordered,
               run_pipeline=build_app.run_pipeline, VERSIONS=build_app.VERSIONS, EVENT_SINK=None)
