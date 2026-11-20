#!/usr/bin/env python3
"""Sequential repository-wide test runner; unavailable tests never count as passed."""
import argparse
from collections import Counter
from dataclasses import dataclass
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

CORE = Path(__file__).resolve().parents[1]


def prepare_tools():
    """Use the same repository-local Windows tools as the product build."""
    if sys.platform == 'win32':
        tools = CORE/'builds/intermediates/tools'
        bins = [CORE/'builds/intermediates/Windows/otp/bin', tools/'elixir/bin']
        os.environ['PATH'] = os.pathsep.join([*(str(p) for p in bins if p.is_dir()), os.environ.get('PATH', '')])
        for name, path in [('MIX_HOME', tools/'mix'), ('HEX_HOME', tools/'hex'), ('MIX_REBAR3', tools/'rebar3')]:
            os.environ.setdefault(name, str(path))


def files(root):
    for directory, names, filenames in os.walk(root):
        names[:] = sorted(n for n in names if n not in
            {'.git', 'builds', '.build', 'deps', 'node_modules', '__pycache__'})
        for name in sorted(filenames):
            yield Path(directory) / name


@dataclass
class Test:
    name: str
    command: list
    cwd: Path
    platform: str = ''
    required: tuple = ()
    modules: tuple = ()
    variables: tuple = ()

    def unavailable(self):
        if self.platform and sys.platform != self.platform:
            return f'requires {self.platform}; this host is {sys.platform}'
        if not shutil.which(str(self.command[0])):
            return f'missing command: {self.command[0]}'
        missing = [v for v in self.variables if not os.environ.get(v)]
        if missing:
            return 'missing environment setting: ' + ', '.join(missing)
        missing = [str(p) for p in self.required if not p.exists()]
        if missing:
            return 'missing build/prerequisite: ' + ', '.join(missing)
        missing = [m for m in self.modules if importlib.util.find_spec(m) is None]
        return 'missing Python module: ' + ', '.join(missing) if missing else ''


def catalog(product):
    result = []
    node22 = Path('/opt/homebrew/opt/node@22/bin/node')
    node = str(node22) if node22.is_file() else 'node'
    for root in (CORE, product):
        paths = list(files(root))
        for p in paths:
            label = f'{root.name}/{p.relative_to(root).as_posix()}'
            if p.name == 'rebar.config' and (p.parent/'test').is_dir():
                rebar = CORE/'builds/intermediates/tools/rebar3'
                command = ['escript', str(rebar)] if sys.platform == 'win32' and rebar.is_file() else ['rebar3']
                result.append(Test(label+' (EUnit)', command + ['do', 'compile,', 'eunit'], p.parent))
            elif p.name == 'mix.exs' and (p.parent/'test').is_dir():
                result.append(Test(label+' (ExUnit)', [shutil.which('mix') or 'mix', 'test'], p.parent))
            elif p.name == 'Package.swift' and (p.parent/'Tests').is_dir():
                result.append(Test(label+' (Swift)', ['swift', 'test', '--package-path', str(p.parent),
                    '--scratch-path', str(root/'builds/test-artifacts'/p.parent.name)], p.parent, 'darwin'))
        for directory in sorted({p.parent for p in paths if p.name.endswith('.test.mjs')}):
            result.append(Test(f'{root.name}/{directory.relative_to(root).as_posix()} (Node)',
                [node, '--test', *map(str, sorted(directory.glob('*.test.mjs')))], directory))
        for p in paths:
            relative = p.relative_to(root).as_posix()
            if relative == 'src/Apps/WebApp/tests/device-view-browser.mjs':
                chrome = os.environ.get('BA_TEST_CHROME') or 'C:/Program Files/Google/Chrome/Application/chrome.exe'
                result.append(Test(f'{root.name}/{relative} (Chromium)',
                    [node, str(p)], root, required=(Path(chrome),)))
            python = p.suffix == '.py' and (p.name.startswith('test_') or
                (relative.startswith('tests/') and (p.name.endswith(('-smoke.py', '-e2e.py'))
                 or p.name in {'smoke.py', 'naming-check.py'})))
            if not python and not (relative.startswith('tests/') and p.suffix == '.escript'):
                continue
            command = [sys.executable, str(p)] if python else ['escript', str(p)]
            platform, required, modules = '', [], ()
            if relative.startswith('tests/apple/'):
                platform = 'darwin'
            if relative.startswith('tests/Windows/') or relative == 'tests/ReceptionDesk/release-smoke.py':
                platform = 'win32'
                required.append(CORE/'builds/Services/ReceptionDesk/bin/reception_desk.bat'
                    if relative == 'tests/ReceptionDesk/release-smoke.py' else product/'builds/Windows/OpenSound')
            if relative.startswith('tests/control/cli-') or p.name == 'desktop-web-instances-smoke.py':
                platform = 'darwin'
            if relative.startswith('tests/control/'):
                required.append(CORE/'builds/intermediates/control/default/lib/ba_core/ebin')
            if p.name == 'desktop-web-instances-smoke.py':
                required.append(product/'builds/WebApp')
            variants = [('default', [])]
            for name, args in variants:
                result.append(Test(f'{root.name}/{relative} [{name}]', command+args,
                    p.parent if p.name.startswith('test_') else root, platform, tuple(required), modules, ()))
    # Integration scripts load the default core ebin, not EUnit's test profile.
    # Build it first, even on a checkout where only test-profile artifacts exist.
    result.sort(key=lambda t: 0 if t.name == f'{CORE.name}/src/control/rebar.config (EUnit)' else 1)
    return result


def execute(tests, env):
    results = []
    for index, test in enumerate(tests, 1):
        print(f'\n== [{index}/{len(tests)}] {test.name}', flush=True)
        reason, started = test.unavailable(), time.monotonic()
        status, code = 'UNAVAILABLE', None
        if not reason:
            try:
                code = subprocess.run(test.command, cwd=test.cwd, env=env).returncode
                status = 'PASSED' if code == 0 else 'FAILED'
            except OSError as error:
                reason = str(error)
        results.append(dict(name=test.name, status=status, exit_code=code, reason=reason,
                            seconds=round(time.monotonic()-started, 3), command=test.command))
        print(f'== {test.name}: {status}' + (f' — {reason}' if reason else ''), flush=True)
    return results


def exit_code(results):
    if any(r['status'] == 'FAILED' for r in results):
        return 1
    return 2 if any(r['status'] != 'PASSED' for r in results) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--product-root', type=Path, default=Path(os.environ.get('OPENSOUND_ROOT', CORE.parent/'OpenSound')))
    parser.add_argument('--list', action='store_true', help='List all suites/variants without executing')
    parser.add_argument('--match', help='Run only names containing this string; explicitly a partial run')
    args = parser.parse_args()
    product = args.product_root.resolve()
    if not (product/'src/Apps').is_dir():
        parser.error(f'OpenSound product checkout not found: {product}')
    prepare_tools()
    tests = catalog(product)
    selected = [t for t in tests if not args.match or args.match in t.name]
    if not selected:
        parser.error('no matching tests')
    if args.list:
        for test in selected:
            reason = test.unavailable()
            print(test.name + (' — UNAVAILABLE: '+reason if reason else ''))
        print(f'{len(selected)}/{len(tests)} registered suites/scenarios; no tests executed.')
        return 0
    env = dict(os.environ, OPENSOUND_ROOT=str(product), BA_TEST_ERL=shutil.which('erl') or 'erl')
    env.setdefault('ERL_LIBS', str(CORE/'builds/intermediates/control/default/lib'))
    env.setdefault('REBAR_CACHE_DIR', str(CORE/'builds/intermediates/rebar-cache'))
    if sys.platform == 'darwin':
        env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
        if Path('/opt/homebrew/opt/openssl@3/lib').exists():
            env.setdefault('BA_TEST_NATIVE_LIBRARY_DIR', '/opt/homebrew/opt/openssl@3/lib')
    folder = CORE/'builds/test-results'/time.strftime('%Y%m%d-%H%M%S')
    folder.mkdir(parents=True, exist_ok=True)
    print('Running registered tests sequentially; some open windows or contact public Reception.\n'
          'Failures do not stop subsequent tests. Unavailable tests make the run incomplete.', flush=True)
    results = execute(selected, env)
    report = folder/'summary.json'
    report.write_text(json.dumps(dict(registered=len(tests), selected=len(selected), results=results), indent=2)+'\n')
    print('\n== Final summary')
    for r in results:
        print(f'{r["status"]}: {r["name"]}' + (f' — {r["reason"]}' if r['reason'] else ''))
    print(dict(Counter(r['status'] for r in results)))
    print(f'Selection: {len(selected)}/{len(tests)} suites/scenarios. Report: {report}')
    print('ALL registered tests passed.' if len(selected)==len(tests) and exit_code(results)==0
          else 'Run failed, incomplete, or limited to a subset; see results above.')
    return exit_code(results)


if __name__ == '__main__':
    sys.exit(main())
