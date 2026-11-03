"""Check the packaged Mac runtime against the shared default public desk."""
import time
from smoke import Instance


def wait(node, predicate, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = node.request('snapshot')
        if predicate(state):
            return state
        time.sleep(.2)
    raise AssertionError(f'Relay state did not converge: {state.get("relay")}')


def swarm(state, identity):
    return next(s for s in state['swarms'] if s['id'] == identity)


if __name__ == '__main__':
    nodes = []
    try:
        nodes = [Instance(71, desk=None), Instance(72, desk=None)]
        a, b = nodes
        states = [wait(n, lambda s: s['relay']['connected']) for n in nodes]
        assert states[0]['relay']['url'].startswith('wss://')
        assert states[0]['relay']['url'] == states[1]['relay']['url']
        assert states[0]['node'] != states[1]['node']
        target = states[0]['swarms'][0]
        assert target['invitation'].startswith('parvi://swarm/v2?')
        assert b.request('join_swarm', invitation=target['invitation'])['error'] is None
        for sender, receiver, text in [(a, b, 'Mac public relay hello'), (b, a, 'Mac public relay reply')]:
            assert sender.request('send_swarm', swarm_id=target['id'], text=text)['error'] is None
            wait(receiver, lambda s: any(m['text'] == text for m in swarm(s, target['id'])['messages']))
        assert b.request('leave_swarm', swarm_id=target['id'])['error'] is None
        wait(a, lambda s: len(swarm(s, target['id'])['members']) == 1)
        print('PASS: packaged Mac runtime, default WSS desk, authentication, invitation, two-way chat and departure')
    finally:
        for node in nodes:
            node.close()
