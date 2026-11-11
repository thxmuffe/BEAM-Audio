"""Verify overlapping buffees, scoped chat, invitations, leave and mutual removal."""
from smoke import Instance, await_state


def buffee(state, buffee_id):
    return next((s for s in state['buffees'] if s['id'] == buffee_id), None)


def wait_buffee(instance, buffee_id, predicate):
    return await_state(instance, lambda state: (s := buffee(state, buffee_id)) is not None and predicate(s))


def main():
    instances = []
    try:
        a, b, c = (Instance(i) for i in range(1, 4))
        instances.extend([a, b, c])
        x = a.request('create_buffee', name='Shared music')['result']['buffee_id']
        y = a.request('create_buffee', name='Another room')['result']['buffee_id']
        invite_x = buffee(a.request('snapshot'), x)['invitation']
        invite_y = buffee(a.request('snapshot'), y)['invitation']
        assert b.request('join_buffee', invitation=invite_x)['error'] is None
        assert c.request('join_buffee', invitation=invite_x)['error'] is None
        assert b.request('join_buffee', invitation=invite_y)['error'] is None
        for instance in [a, b, c]:
            wait_buffee(instance, x, lambda s: len(s['members']) == 3)
        wait_buffee(b, y, lambda s: len(s['members']) == 2)
        assert a.request('send_buffee', buffee_id=x, text='Music buffee hello 🐦')['error'] is None
        for instance in [b, c]:
            wait_buffee(instance, x, lambda s: any(m['text'] == 'Music buffee hello 🐦' for m in s['messages']))
        assert a.request('send_buffee', buffee_id=y, text='Only the other room')['error'] is None
        wait_buffee(b, y, lambda s: any(m['text'] == 'Only the other room' for m in s['messages']))
        assert buffee(c.request('snapshot'), y) is None
        assert all(m['text'] != 'Only the other room' for m in buffee(b.request('snapshot'), x)['messages'])
        assert c.request('send_buffee', buffee_id=y, text='Not a member')['error'] is not None

        assert b.request('remove_both', buffee_id=x, target=c.node)['error'] is None
        await_state(b, lambda state: buffee(state, x) is None)
        await_state(c, lambda state: buffee(state, x) is None)
        wait_buffee(a, x, lambda s: s['members'] == [a.node])
        assert buffee(b.request('snapshot'), y) is not None
        assert b.request('join_buffee', invitation=invite_x)['error'] is not None
        fresh_invitation = buffee(a.request('snapshot'), x)['invitation']
        assert fresh_invitation != invite_x
        assert b.request('join_buffee', invitation=fresh_invitation)['error'] is None
        wait_buffee(a, x, lambda s: len(s['members']) == 2)
        assert a.request('send_buffee', buffee_id=y, text='Other membership survives')['error'] is None
        wait_buffee(b, y, lambda s: any(m['text'] == 'Other membership survives' for m in s['messages']))

        # The original creator leaves; the remaining member can still admit peers.
        assert a.request('leave_buffee', buffee_id=x)['error'] is None
        await_state(a, lambda state: buffee(state, x) is None)
        wait_buffee(b, x, lambda s: s['members'] == [b.node])
        invitation_b = buffee(b.request('snapshot'), x)['invitation']
        assert c.request('join_buffee', invitation=invitation_b)['error'] is None
        assert c.request('send_buffee', buffee_id=x, text='No creator required')['error'] is None
        wait_buffee(b, x, lambda s: any(m['text'] == 'No creator required' for m in s['messages']))
        assert buffee(a.request('snapshot'), y) is not None
        assert all(m['text'] != 'No creator required' for m in buffee(a.request('snapshot'), y)['messages'])
        assert a.request('send_buffee', buffee_id=x, text='Former member')['error'] is not None
        print('PASS: three nodes, overlapping buffees, isolated chat, scoped mutual removal, invitation revocation, re-admission and creator-independent leave')
    finally:
        for instance in reversed(instances):
            instance.close()


if __name__ == '__main__':
    main()
