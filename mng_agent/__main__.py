"""python3 -m mng_agent <command>: run the agent, or drive it from a terminal (everything the app can do).

    serve                       run the agent in the foreground (the LaunchAgent runs this)
    install / uninstall         install or remove the LaunchAgent (starts the agent at login and keeps it running)
    stop                        ask the running agent to stop
    status                      agent, toolchain and active builds
    detect FILE...              what dropped files are (game, update, keys)
    build GAME [--update U] [--keys K] [--platform macos|ios] [--out O] [--work W] [--wait]
    jobs | job ID | log ID [-f] | cancel ID
    library | launch [APP] | rebuild APP | forget APP
    settings [KEY=VALUE ...]    show or change settings; game.<name>=<value> for game settings
    mods [VERSION] | mods-add FOLDER VERSION [--name N] | mods-enable ID | mods-disable ID | mods-remove ID | mods-import VERSION
    diagnostics [--export ZIP]
    watch                       print events as they happen
"""
import argparse
import json
import sys
import time

from . import VERSION, agent_home, launchd


def _client():
    from .client import AgentClient
    return AgentClient()


def _print(obj):
    print(json.dumps(obj, indent=2, default=str))


def _job_line(job):
    done = sum(s['status'] in ('done', 'resumed', 'skipped') for s in job['steps'])
    step = next((s['title'] for s in job['steps'] if s['name'] == job.get('current_step')), job.get('current_step') or '')
    return (f'{job["id"]}  {job["status"]:<9}  {done}/{len(job["steps"]) or "?"}  {step}  '
            f'{job["params"].get("out", "")}' + (f'\n    error: {job["error"]}' if job.get('error') else ''))


def _follow(client, job_id):
    """Print a job's log and step changes until it finishes; exit status 0 only when it succeeded."""
    from .client import AgentClient
    with AgentClient(timeout=None) as watcher:
        for event in watcher.events():
            if event.get('event') == 'job.log' and event.get('job') == job_id:
                print(event['message'], flush=True)
            elif event.get('event') == 'job' and event['job']['id'] == job_id:
                job = event['job']
                if job['status'] in ('succeeded', 'failed', 'cancelled'):
                    print(_job_line(job))
                    return 0 if job['status'] == 'succeeded' else 1
    return 1


def _value(text):
    if text in ('true', 'false'):
        return text == 'true'
    if text in ('none', 'null', ''):
        return None
    try:
        return int(text)
    except ValueError:
        return text


def main(argv=None):
    parser = argparse.ArgumentParser(prog='python3 -m mng_agent', description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    parser.add_argument('--version', action='version', version=VERSION)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('serve')
    p = sub.add_parser('install')
    p.add_argument('--repo', help='the MacNativeGames checkout (default: this one)')
    sub.add_parser('uninstall')
    sub.add_parser('stop')
    sub.add_parser('status')
    p = sub.add_parser('detect')
    p.add_argument('paths', nargs='+')
    p = sub.add_parser('build')
    p.add_argument('game')
    for flag in ('--update', '--keys', '--out', '--work', '--firmware', '--shared-fonts'):
        p.add_argument(flag)
    p.add_argument('--platform', choices=('macos', 'ios'), default='macos')
    p.add_argument('--wait', action='store_true', help='follow the build until it ends')
    sub.add_parser('jobs')
    for name in ('job', 'cancel'):
        sub.add_parser(name).add_argument('id')
    p = sub.add_parser('log')
    p.add_argument('id')
    p.add_argument('-f', '--follow', action='store_true')
    p.add_argument('-n', '--lines', type=int, default=200)
    sub.add_parser('library')
    sub.add_parser('launch').add_argument('app', nargs='?')
    sub.add_parser('rebuild').add_argument('app')
    sub.add_parser('forget').add_argument('app')
    sub.add_parser('settings').add_argument('assignments', nargs='*', metavar='KEY=VALUE')
    sub.add_parser('mods').add_argument('version', nargs='?')
    p = sub.add_parser('mods-add')
    p.add_argument('folder')
    p.add_argument('version')
    p.add_argument('--name')
    for name in ('mods-enable', 'mods-disable', 'mods-remove'):
        sub.add_parser(name).add_argument('id')
    sub.add_parser('mods-import').add_argument('version')
    sub.add_parser('diagnostics').add_argument('--export', metavar='ZIP')
    sub.add_parser('watch')
    args = parser.parse_args(argv)

    from .client import AgentError, AgentUnavailable
    try:
        if args.command == 'serve':
            from .server import run
            return run()
        if args.command == 'install':
            path = launchd.install(repo=args.repo)
            print(f'installed {path}; the agent starts now and at every login')
            for _ in range(50):
                try:
                    with _client() as c:
                        print(f'agent {c.call("hello")["version"]} is running')
                        return 0
                except AgentUnavailable:
                    time.sleep(0.2)
            print(f'installed, but the agent did not answer yet; see {agent_home() / "agent.log"}', file=sys.stderr)
            return 1
        if args.command == 'uninstall':
            print('removed the LaunchAgent' if launchd.uninstall() else 'no LaunchAgent was installed')
            return 0
        with _client() as c:
            cmd = args.command
            if cmd == 'stop':
                c.call('shutdown')
                print('the agent is stopping')
            elif cmd == 'status':
                s = c.call('status')
                hello = c.call('hello')
                print(f'agent {hello["version"]} (pid {hello["pid"]}), repo {hello["repo"]}')
                print('toolchain ready' if s['toolchain']['ready'] else
                      'toolchain incomplete: ' + ', '.join(k for k, v in s['toolchain'].items() if k != 'ready' and v in (None, False)))
                for job in s['active']:
                    print(_job_line(job))
                print(f'{s["library"]} app(s) in the library')
            elif cmd == 'detect':
                _print(c.call('detect', paths=args.paths))
            elif cmd == 'build':
                params = {k: v for k, v in dict(game=args.game, update=args.update, keys=args.keys, out=args.out,
                                                 work=args.work, firmware=args.firmware, shared_fonts=args.shared_fonts,
                                                 platform=args.platform).items() if v}
                job = c.call('build.submit', **params)
                print(f'queued job {job["id"]} -> {job["params"]["out"]}')
                if args.wait:
                    return _follow(c, job['id'])
            elif cmd == 'jobs':
                for job in c.call('jobs.list'):
                    print(_job_line(job))
            elif cmd == 'job':
                _print(c.call('jobs.get', id=args.id))
            elif cmd == 'cancel':
                print(_job_line(c.call('jobs.cancel', id=args.id)))
            elif cmd == 'log':
                for line in c.call('jobs.log', id=args.id, tail=args.lines)['lines']:
                    print(line)
                if args.follow:
                    return _follow(c, args.id)
            elif cmd == 'library':
                for app in c.call('library.list'):
                    flags = ' '.join(f for f in ('stale' if app.get('stale') else '', 'missing' if app.get('missing') else '') if f)
                    print(f'{app["display_version"]:<6} {app["platform"]:<6} {app["path"]} {flags}')
            elif cmd == 'launch':
                _print(c.call('launch', **({'path': args.app} if args.app else {})))
            elif cmd == 'rebuild':
                print(_job_line(c.call('library.rebuild', path=args.app)))
            elif cmd == 'forget':
                _print(c.call('library.remove', path=args.app))
            elif cmd == 'settings':
                if not args.assignments:
                    _print(c.call('settings.get'))
                else:
                    values, game = {}, {}
                    for item in args.assignments:
                        key, sep, value = item.partition('=')
                        if not sep:
                            parser.error(f'{item}: expected KEY=VALUE')
                        if key.startswith('game.'):
                            game[key[5:]] = None if value == '' else value
                        else:
                            values[key] = _value(value)
                    if game:
                        values['game'] = game
                    _print(c.call('settings.set', values=values))
            elif cmd == 'mods':
                _print(c.call('mods.list', **({'version': args.version} if args.version else {})))
            elif cmd == 'mods-add':
                _print(c.call('mods.add', source=args.folder, version=args.version,
                              **({'name': args.name} if args.name else {})))
            elif cmd in ('mods-enable', 'mods-disable'):
                _print(c.call('mods.enable', id=args.id, enabled=cmd == 'mods-enable'))
            elif cmd == 'mods-remove':
                _print(c.call('mods.remove', id=args.id))
            elif cmd == 'mods-import':
                _print(c.call('mods.import', version=args.version))
            elif cmd == 'diagnostics':
                if args.export:
                    print(c.call('diagnostics.export', destination=args.export)['path'])
                else:
                    _print(c.call('diagnostics.report'))
            elif cmd == 'watch':
                for event in c.events():
                    print(json.dumps(event, default=str), flush=True)
        return 0
    except AgentUnavailable as e:
        print(e, file=sys.stderr)
        return 3
    except AgentError as e:
        print(f'error ({e.code}): {e.message}', file=sys.stderr)
        return 1
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == '__main__':
    sys.exit(main())
