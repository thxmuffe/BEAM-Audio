"""Verify a deployed desk with two disposable native BEAM clients."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import argparse
import time
from urllib.parse import unquote

spec = spec_from_file_location('relay_smoke', Path(__file__).with_name('relay-smoke.py'))
r = module_from_spec(spec)
spec.loader.exec_module(r)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url', nargs='?', help='Override the bundled default desk URL')
    args = parser.parse_args()
    if args.url is not None and not args.url.startswith('wss://'):
        parser.error('Public verification requires WSS')
    nodes = []
    try:
        for _ in range(2):
            nodes.append(r.Node(args.url))
        a, b = nodes
        states = [r.wait(n, lambda s: s['relay']['connected']) for n in nodes]
        url = args.url or states[0]['relay']['url']
        assert url.startswith('wss://')
        assert all(s['relay']['url'] == url for s in states)
        assert states[0]['node'] != states[1]['node']
        swarm = states[0]['swarms'][0]
        assert url in unquote(swarm['invitation'])
        assert b.request('join_swarm', invitation=swarm['invitation'])['error'] is None
        for sender, receiver, message in ((a, b, 'Public WSS hello'), (b, a, 'Public WSS reply')):
            assert sender.request('send_swarm', swarm_id=swarm['id'], text=message)['error'] is None
            r.wait(receiver, lambda s: any(m['text'] == message for m in r.swarm(s, swarm['id'])['messages']))
        time.sleep(50)
        assert all(n.request()['relay']['connected'] for n in nodes)
        assert a.request('send_swarm', swarm_id=swarm['id'], text='After idle')['error'] is None
        r.wait(b, lambda s: any(m['text'] == 'After idle' for m in r.swarm(s, swarm['id'])['messages']))
        assert b.request('leave_swarm', swarm_id=swarm['id'])['error'] is None
        r.wait(a, lambda s: len(r.swarm(s, swarm['id'])['members']) == 1)
        print('PASS: public WSS trust/authentication, invitation, bidirectional chat, idle connection and departure')
    finally:
        for node in nodes:
            node.close()


if __name__ == '__main__':
    main()
