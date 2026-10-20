"""One build, as a supervised subprocess of the agent: python3 -m mng_agent.runner <spec.json>

The spec names the job, its parameters and the steps an earlier attempt completed. The runner runs build_app.py's step
graph and writes one JSON event per line to its standard output (the agent's only channel from it); everything the
build prints goes to standard error, which the agent keeps as the job's log.

    {"type": "plan", "steps": [{"name", "title", "applies"}]}
    {"type": "step", "name", "status": running|done|skipped|resumed|failed, "error"?}
    {"type": "log", "message"}
    {"type": "result", "app", "version", "display_version", "platform"}
    {"type": "error", "message", "kind": build|internal|cancelled}

Exit status: 0 done, 1 the build stopped (BuildError), 2 an internal error, 130 cancelled.
"""
import importlib
import json
import os
import signal
import sys
import threading
import traceback
from pathlib import Path

_out = None
_lock = threading.Lock()


def emit(event_type, **fields):
    line = json.dumps(dict(fields, type=event_type), default=str)
    with _lock:
        _out.write(line + '\n')
        _out.flush()


def arguments(params):
    """build_app.py's command line for a job's parameters."""
    argv = [params['game'], '--keys', params['keys'], '--platform', params.get('platform') or 'macos']
    for key, flag in (('update', '--update'), ('out', '--out'), ('work', '--work'), ('firmware', '--firmware'),
                      ('shared_fonts', '--shared-fonts')):
        if params.get(key):
            argv += [flag, params[key]]
    if params.get('no_shader_reminder'):
        argv.append('--no-shader-reminder')
    return [str(a) for a in argv]


def load_build(repo):
    """build_app from the configured checkout, or a test pipeline named by MNG_AGENT_PIPELINE (module:attribute)."""
    override = os.environ.get('MNG_AGENT_PIPELINE')
    if override:
        module, _, attr = override.partition(':')
        return getattr(importlib.import_module(module), attr or 'BUILD')
    sys.path.insert(0, str(repo))
    import build_app
    return build_app


def _terminate(signum, frame):
    raise KeyboardInterrupt


def main(argv):
    global _out
    if len(argv) != 1:
        print('usage: python3 -m mng_agent.runner <spec.json>', file=sys.stderr)
        return 2
    # Events own the real stdout; whatever the build prints goes to stderr (the job log).
    _out = os.fdopen(os.dup(1), 'w', buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    signal.signal(signal.SIGTERM, _terminate)
    spec = json.loads(Path(argv[0]).read_text())
    try:
        build = load_build(spec.get('repo') or Path(__file__).resolve().parents[1])
        build.EVENT_SINK = lambda event_type, **fields: emit(event_type, **fields)
        context = build.plan(build.parse_args(arguments(spec['params'])))
        steps = build.ordered(build.STEPS)
        emit('plan', steps=[{'name': s.name, 'title': s.title, 'applies': bool(s.when(context))} for s in steps])

        def on_step(step, status, error=None):
            fields = {'name': step.name, 'status': status}
            if error is not None and not isinstance(error, KeyboardInterrupt):
                fields['error'] = str(error).splitlines()[0][:500] if str(error) else type(error).__name__
            emit('step', **fields)

        build.run_pipeline(context, build.STEPS, completed=set(spec.get('completed') or ()), on_step=on_step)
        versions = getattr(build, 'VERSIONS', {})
        emit('result', app=str(context.out), version=context.version, platform=context.platform,
             display_version=versions.get(context.version, {}).get('display_version', context.version))
        return 0
    except KeyboardInterrupt:
        emit('error', kind='cancelled', message='cancelled')
        return 130
    except Exception as e:   # noqa: BLE001 - every failure becomes an event the app can show
        build_error = type(e).__name__ == 'BuildError'
        if not build_error:
            traceback.print_exc()
        emit('error', kind='build' if build_error else 'internal', message=str(e) or type(e).__name__)
        return 1 if build_error else 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
