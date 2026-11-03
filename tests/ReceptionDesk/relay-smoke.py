"""Real relay, three non-distributed BEAM clients, no third-party Python packages."""
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import threading
import time
import urllib.request
import sys

ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = Path(os.environ.get("OPENSOUND_ROOT", ROOT.parent / "OpenSound"))
APP = APP_ROOT / 'builds/Windows/Parvi'
ERL = Path(os.environ.get('PARVI_TEST_ERL', APP / 'runtime/bin/erl.exe'))
ELIXIR = Path(os.environ.get('PARVI_ELIXIR_ROOT', ROOT / 'builds/intermediates/tools/elixir'))


class Node:
    def __init__(self, desk, extra_env=None):
        self.lines = queue.Queue()
        env = dict(os.environ)
        env.pop('PARVI_RECEPTION_DESK_URL', None)
        if desk is not None:
            env['PARVI_RECEPTION_DESK_URL'] = desk
        env.update(extra_env or {})
        # Deliberately no -name/-sname: Distributed Erlang cannot carry any traffic.
        self.process = subprocess.Popen([str(ERL), '-noshell', '-pa', str(APP / 'ebin'),
            '-s', 'parvi_bridge', 'main'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=None if '--verbose' in sys.argv else subprocess.DEVNULL, text=True, encoding='utf-8',
            env=env)
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            try:
                self.lines.put(json.loads(line))
            except json.JSONDecodeError:
                if '--verbose' in sys.argv:
                    print(line.rstrip(), file=sys.stderr)

    def request(self, method='snapshot', **fields):
        self.process.stdin.write(json.dumps(dict(method=method, **fields)) + '\n')
        self.process.stdin.flush()
        return self.lines.get(timeout=12)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def wait(node, predicate):
    end = time.monotonic() + 20
    while time.monotonic() < end:
        reply = node.request()
        if predicate(reply):
            return reply
        time.sleep(.1)
    raise AssertionError('State did not converge')


def swarm(state, identity):
    return next((s for s in state['swarms'] if s['id'] == identity), None)


def start_desk(port, tls_port=None, cert=None, key=None):
    paths = list((ROOT / 'builds/intermediates/ReceptionDeskMix/dev/lib').glob('*/ebin'))
    paths += list((ELIXIR / 'lib').glob('*/ebin'))
    assert paths, 'Compile the Phoenix service first'
    tls = '' if tls_port is None else (',{https,[{ip,{127,0,0,1}},{port,' + str(tls_port) + '},'
        '{certfile,' + json.dumps(str(cert).replace('\\', '/')) + '},'
        '{keyfile,' + json.dumps(str(key).replace('\\', '/')) + '}]}')
    config = ("application:load(reception_desk), application:set_env(reception_desk, "
        "'Elixir.ReceptionDesk.Endpoint', [{adapter,'Elixir.Phoenix.Endpoint.Cowboy2Adapter'},"
        "{server,true},{http,[{ip,{127,0,0,1}},{port," + str(port) + "}]},"
        "{pubsub_server,'Elixir.ReceptionDesk.PubSub'},"
        "{secret_key_base,<<\"local-test-secret-key-base-is-not-a-client-credential-12345678901234567890\">>}" + tls + " ]),"
        "{ok,_}=application:ensure_all_started(reception_desk), receive stop -> ok end.")
    proc = subprocess.Popen([str(ERL), '-noshell', '-noinput', '-pa', *map(str, paths), '-eval', config],
                            stdout=None if '--verbose' in sys.argv else subprocess.DEVNULL,
                            stderr=None if '--verbose' in sys.argv else subprocess.DEVNULL)
    for _ in range(100):
        if proc.poll() is not None:
            raise RuntimeError('Desk startup failed')
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=.2):
                return proc
        except OSError:
            time.sleep(.1)
    proc.kill()
    proc.wait()
    raise TimeoutError('Desk startup')


def main():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    desk = start_desk(port)
    nodes = []
    try:
        url = f'ws://127.0.0.1:{port}/relay/v1'
        a, b, c = Node(''), Node(url), Node(url)
        nodes.extend([a, b, c])
        assert a.request()['node'] == 'nonode@nohost'
        configured = a.request('configure_desk', url=url, request_id='configure-test')
        assert configured['error'] is None and configured['request_id'] == 'configure-test'
        states = [wait(n, lambda s: s['relay']['connected']) for n in nodes]
        assert len(set(s['node'] for s in states)) == 3
        assert all(len(s['node']) == 64 for s in states)
        x = states[0]['swarms'][0]['id']
        link = swarm(a.request(), x)['invitation']
        assert '/v2?' in link and 'cookie=' not in link
        assert b.request('join_swarm', invitation=link)['error'] is None
        link_b = swarm(b.request(), x)['invitation']
        assert c.request('join_swarm', invitation=link_b)['error'] is None
        for n in nodes:
            wait(n, lambda s: len(swarm(s, x)['members']) == 3)
        if '--idle' in sys.argv:
            # Longer than the server's inactivity timeout: ping/pong must keep it open.
            time.sleep(50)
            assert all(n.request()['relay']['connected'] for n in nodes)
        y = a.request('create_swarm', name='Another room')['result']['swarm_id']
        assert b.request('join_swarm', invitation=swarm(a.request(), y)['invitation'])['error'] is None
        assert a.request('send_swarm', swarm_id=x, text='Relayed hello 🐦')['error'] is None
        for n in (b, c):
            wait(n, lambda s: any(m['text'] == 'Relayed hello 🐦' for m in swarm(s, x)['messages']))
        assert b.request('send_swarm', swarm_id=y, text='Only another room')['error'] is None
        wait(a, lambda s: any(m['text'] == 'Only another room' for m in swarm(s, y)['messages']))
        assert swarm(c.request(), y) is None
        assert c.request('send_swarm', swarm_id=y, text='Unauthorized')['error'] is not None
        # The service stores neither histories nor memberships. Native state survives restart.
        desk.terminate()
        desk.wait(timeout=5)
        wait(a, lambda s: not s['relay']['connected'])
        desk = start_desk(port)
        for n in nodes:
            wait(n, lambda s: s['relay']['connected'] and len(s['relay']['online']) >= 3)
        assert c.request('send_swarm', swarm_id=x, text='After desk restart')['error'] is None
        wait(a, lambda s: any(m['text'] == 'After desk restart' for m in swarm(s, x)['messages']))
        assert b.request('remove_both', swarm_id=x, target=states[2]['node'])['error'] is None
        wait(c, lambda s: swarm(s, x) is None)
        wait(a, lambda s: len(swarm(s, x)['members']) == 1)
        assert swarm(b.request(), y) is not None
        assert b.request('join_swarm', invitation=link)['error'] is not None
        fresh = swarm(a.request(), x)['invitation']
        assert fresh != link
        assert b.request('join_swarm', invitation=fresh)['error'] is None
        assert a.request('leave_swarm', swarm_id=x)['error'] is None
        wait(b, lambda s: len(swarm(s, x)['members']) == 1)
        assert c.request('join_swarm', invitation=swarm(b.request(), x)['invitation'])['error'] is None
        print('PASS: authenticated relay; three independent non-distributed BEAM nodes; scoped admission/chat; desk restart/reconnect; mutual removal/revocation; creator-independent invitation')
    finally:
        for n in nodes:
            n.close()
        desk.terminate()
        desk.wait(timeout=5)


if __name__ == '__main__':
    main()
