"""Verify overlapping swarms, scoped chat, invitations, leave and mutual removal."""
from smoke import Instance, await_state


def swarm(state, swarm_id):
    return next((s for s in state['swarms'] if s['id'] == swarm_id), None)


def wait_swarm(instance, swarm_id, predicate):
    return await_state(instance, lambda state: (s := swarm(state, swarm_id)) is not None and predicate(s))


def main():
    instances = []
    try:
        a, b, c = (Instance(i) for i in range(1, 4))
        instances.extend([a, b, c])
        x = a.request('create_swarm', name='Shared music')['result']['swarm_id']
        y = a.request('create_swarm', name='Another room')['result']['swarm_id']
        invite_x = swarm(a.request('snapshot'), x)['invitation']
        invite_y = swarm(a.request('snapshot'), y)['invitation']
        assert b.request('join_swarm', invitation=invite_x)['error'] is None
        assert c.request('join_swarm', invitation=invite_x)['error'] is None
        assert b.request('join_swarm', invitation=invite_y)['error'] is None
        for instance in [a, b, c]:
            wait_swarm(instance, x, lambda s: len(s['members']) == 3)
        wait_swarm(b, y, lambda s: len(s['members']) == 2)
        assert a.request('send_swarm', swarm_id=x, text='Music swarm hello 🐦')['error'] is None
        for instance in [b, c]:
            wait_swarm(instance, x, lambda s: any(m['text'] == 'Music swarm hello 🐦' for m in s['messages']))
        assert a.request('send_swarm', swarm_id=y, text='Only the other room')['error'] is None
        wait_swarm(b, y, lambda s: any(m['text'] == 'Only the other room' for m in s['messages']))
        assert swarm(c.request('snapshot'), y) is None
        assert all(m['text'] != 'Only the other room' for m in swarm(b.request('snapshot'), x)['messages'])
        assert c.request('send_swarm', swarm_id=y, text='Not a member')['error'] is not None

        assert b.request('remove_both', swarm_id=x, target=c.node)['error'] is None
        await_state(b, lambda state: swarm(state, x) is None)
        await_state(c, lambda state: swarm(state, x) is None)
        wait_swarm(a, x, lambda s: s['members'] == [a.node])
        assert swarm(b.request('snapshot'), y) is not None
        assert b.request('join_swarm', invitation=invite_x)['error'] is not None
        fresh_invitation = swarm(a.request('snapshot'), x)['invitation']
        assert fresh_invitation != invite_x
        assert b.request('join_swarm', invitation=fresh_invitation)['error'] is None
        wait_swarm(a, x, lambda s: len(s['members']) == 2)
        assert a.request('send_swarm', swarm_id=y, text='Other membership survives')['error'] is None
        wait_swarm(b, y, lambda s: any(m['text'] == 'Other membership survives' for m in s['messages']))

        # The original creator leaves; the remaining member can still admit peers.
        assert a.request('leave_swarm', swarm_id=x)['error'] is None
        await_state(a, lambda state: swarm(state, x) is None)
        wait_swarm(b, x, lambda s: s['members'] == [b.node])
        invitation_b = swarm(b.request('snapshot'), x)['invitation']
        assert c.request('join_swarm', invitation=invitation_b)['error'] is None
        assert c.request('send_swarm', swarm_id=x, text='No creator required')['error'] is None
        wait_swarm(b, x, lambda s: any(m['text'] == 'No creator required' for m in s['messages']))
        assert swarm(a.request('snapshot'), y) is not None
        assert all(m['text'] != 'No creator required' for m in swarm(a.request('snapshot'), y)['messages'])
        assert a.request('send_swarm', swarm_id=x, text='Former member')['error'] is not None
        print('PASS: three nodes, overlapping swarms, isolated chat, scoped mutual removal, invitation revocation, re-admission and creator-independent leave')
    finally:
        for instance in reversed(instances):
            instance.close()


if __name__ == '__main__':
    main()
