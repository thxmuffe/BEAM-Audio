"""Steps 2/2a: invitation admission, revocation and the shared OTP chat core.

The local parent supplies only user invitations, SDP/ICE and test commands.
Admission proofs and per-connection OTP cookies stay on encrypted DataChannels.
"""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import queue
import secrets
import os
import shutil
import subprocess
import time
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

spec = spec_from_file_location('carrier', Path(__file__).with_name('otp-dist-smoke.py'))
carrier = module_from_spec(spec)
spec.loader.exec_module(carrier)
subprocess.run([shutil.which('rebar3'), 'compile'], cwd=carrier.ROOT / 'src/control',
    env=dict(os.environ, REBAR_CACHE_DIR=str(carrier.ROOT / 'builds/intermediates/rebar-cache')), check=True)
carrier.paths += list((carrier.ROOT / 'builds/intermediates/control/default/lib').glob('*/ebin'))
routes = {}


def pump():
    for p in carrier.probes:
        while True:
            try:
                m = p.lines.get_nowait()
            except queue.Empty:
                break
            if 'request' in m:
                p.replies[m['request']] = m
            elif m['event'] == 'booted':
                p.booted = m['identity']
            elif m['event'] == 'signal':
                other = routes[p, m['connection']]
                other.post('signal', connection=m['connection'], signal=m['signal'])
            elif m['event'] == 'ready':
                p.channels_ready.add(m['connection'])
            elif m['event'] == 'authorized':
                p.authorized.add(m['connection'])
            elif m['event'] == 'rejected':
                p.rejected.add(m['connection'])
            elif m['event'] == 'chat':
                p.chat_events.append(m['message'])
        assert p.process.poll() is None, f'{p.label} exited; inspect {p.log_path}'


carrier.pump = pump


def node(label):
    name = f'parvi_trust_{label}_{secrets.token_hex(5)}@127.0.0.1'
    p = carrier.Probe(f'trust-{label}', name, name, secrets.token_hex(32), entry='parvi_trust_probe')
    p.channels_ready, p.authorized, p.rejected = set(), set(), set()
    p.chat_events = []
    carrier.probes.append(p)
    carrier.wait(lambda: p.booted is not None)
    state = p.request('status')
    assert state['legacy_workers'] == [] and sorted(state['workers']) == ['parvi_chat', 'parvi_pg']
    return p


def invitation(p, ttl=259200):
    link = p.request('invite', ttl=ttl)['ok']
    assert link.startswith('parvi://cluster/v1?') and 'cookie' not in link
    return link


def open_channel(server, client, connection, link=None, raw=False):
    routes[server, connection], routes[client, connection] = client, server
    role = dict(role='raw') if raw else (dict(role='join', invitation=link) if link else
                                         dict(role='member', peer=server.booted['id']))
    assert client.request('start', connection=connection, **role) is True
    assert server.request('start', connection=connection, role='server') is True
    carrier.wait(lambda: connection in server.channels_ready and connection in client.channels_ready)


def connect(server, client, connection, link=None):
    open_channel(server, client, connection, link)
    carrier.wait(lambda: connection in server.authorized and connection in client.authorized)
    assert server.request('accept', connection=connection) is True
    assert client.request('connect', peer=server.booted['node']) is True
    carrier.wait(lambda: server.booted['node'] in client.request('status')['connected'])


def rejected(server, client, connection, link):
    open_channel(server, client, connection, link)
    carrier.wait(lambda: connection in server.rejected or connection in client.rejected)
    assert connection not in server.authorized and connection not in client.authorized


def change(link, **fields):
    parts = urlsplit(link)
    values = dict(parse_qsl(parts.query))
    values.update(fields)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(values), parts.fragment))


def membership(p):
    policy = p.request('status')['policy']
    return set() if policy is None else set(policy['members'])


def chat_group(nodes):
    names = {p.booted['node'] for p in nodes}
    def converged():
        for p in nodes:
            state = p.request('status')
            assert state['legacy_workers'] == []
            if set(state['chat']['nodes']) != names or state['chat']['process_count'] != len(names):
                return False
        return True
    carrier.wait(converged)


def chat(sender, receivers, label, excluded=()):
    text = f'{label} 🐦 {secrets.token_hex(5)}'
    sender.request('chat_send', text=text)
    carrier.wait(lambda: all(any(m['text'] == text for m in p.request('status')['chat']['messages'])
                            for p in receivers))
    carrier.wait(lambda: all(any(m['text'] == text for m in p.chat_events) for p in receivers))
    assert all(sum(m['text'] == text for m in p.chat_events) == 1 for p in receivers)
    assert all(not any(m['text'] == text for m in p.request('status')['chat']['messages']) for p in excluded)


try:
    a, b = node('a'), node('b')
    genesis = a.request('create')['ok']
    ab_link = invitation(a)
    connect(a, b, 'ab', ab_link)
    assert a.request('exercise', peer=b.booted['node'])['remote_execution']
    assert membership(a) == membership(b) == {a.booted['id'], b.booted['id']}
    chat_group([a, b])
    chat(a, [a, b], 'Native shared chat')
    chat(b, [a, b], 'Native shared chat reply')
    print('PASS: invitation admission; DTLS-bound signed proofs; fresh pairwise OTP cookie; native remote execution', flush=True)

    d = node('d')
    open_channel(a, d, 'unauthorized', raw=True)
    assert a.request('accept', connection='unauthorized') == {'error': 'unauthorized'}
    assert d.request('preauth_native', connection='unauthorized', peer=a.booted['node']) == {
        'accepted': False, 'connected': False}
    assert d.request('preauth_header', connection='unauthorized') is True
    carrier.wait(lambda: not a.request('status')['connections']['unauthorized']['ready'], timeout=2)
    print('PASS: routing a WebRTC channel is not authorization; native admission fails closed', flush=True)
    chat_group([d])
    chat(a, [a, b], 'Unauthorized device excluded', excluded=[d])

    for mode in ['binding', 'nonce', 'signature', 'name', 'malformed']:
        conn = f'replay-{mode}'
        open_channel(a, b, conn, raw=True)
        # Wait for the challenge to reach the held raw endpoint before crafting a test proof.
        time.sleep(.1)
        b.request('replay', **{'from': 'ab', 'to': conn, 'mode': mode})
        carrier.wait(lambda: conn in a.rejected)
        assert conn not in a.authorized
    assert a.request('exercise', peer=b.booted['node'])['monitor']
    print('PASS: session/nonce replay, forged signatures, name impersonation and malformed claims rejected; live link unaffected', flush=True)

    secret = dict(parse_qsl(urlsplit(ab_link).query))['secret']
    bad = change(ab_link, secret=('A' if secret[0] != 'A' else 'B') + secret[1:])
    rejected(a, d, 'bad-secret', bad)
    short = invitation(a, ttl=1)
    time.sleep(1.2)
    denied = d.request('start', connection='expired-local', role='join', invitation=short)
    assert 'error' in denied
    # Changing a URL's expiry cannot revive the server's expired capability.
    rejected(a, d, 'expired-server', change(short, expires=str(int(time.time()) + 1000)))
    assert membership(a) == {a.booted['id'], b.booted['id']}
    print('PASS: incorrect tokens and expired invitations rejected, including tampered expiry dates', flush=True)

    c = node('c')
    connect(b, c, 'bc', invitation(b))
    connect(a, c, 'ac')
    cd_link = invitation(c)
    connect(c, d, 'cd', cd_link)
    connect(a, d, 'ad')
    connect(b, d, 'bd')
    all_ids = {p.booted['id'] for p in [a, b, c, d]}
    assert all(membership(p) == all_ids for p in [a, b, c, d])
    print('PASS: any admitted node can invite; four independent VMs form one authenticated native cluster', flush=True)
    chat_group([a, b, c, d])
    for sender in [a, b, c, d]:
        chat(sender, [a, b, c, d], 'Four-node pg delivery')
    restarted = b.request('restart_chat')
    assert restarted['old'] != restarted['new']
    chat_group([a, b, c, d])
    assert b.request('status')['chat']['subscribers'] == 1
    chat(a, [a, b, c, d], 'Observer survives chat restart')
    restarted = b.request('restart_pg')
    assert restarted['old'] != restarted['new']
    chat_group([a, b, c, d])
    assert b.request('status')['chat']['subscribers'] == 0
    assert b.request('subscribe') is True
    chat(b, [a, b, c, d], 'Scope restart and explicit resubscription')
    print('PASS: shared chat uses native pg groups; one observer event per test send; worker and scope restart recovery', flush=True)

    foreign = node('foreign')
    foreign.request('create')
    foreign_link = invitation(foreign)
    denied = b.request('start', connection='foreign-domain', role='join', invitation=foreign_link)
    assert 'error' in denied
    assert membership(b) == all_ids
    foreign.close()
    carrier.probes.remove(foreign)
    print('PASS: an unrelated invitation cannot silently merge populated VM trust domains', flush=True)

    c.request('save_cookie', peer=d.booted['node'])
    d.request('save_cookie', peer=c.booted['node'])
    b.request('remove_both', target=d.booted['id'])
    survivors = {a.booted['id'], c.booted['id']}
    carrier.wait(lambda: membership(a) == membership(c) == survivors)
    carrier.wait(lambda: a.request('status')['connected'] == [c.booted['node']] and
                 c.request('status')['connected'] == [a.booted['node']] and
                 not b.request('status')['connected'] and not d.request('status')['connected'])
    assert a.request('exercise', peer=c.booted['node'])['link']
    chat_group([a, c])
    chat_group([b])
    chat_group([d])
    chat(a, [a, c], 'Removed nodes excluded from live group', excluded=[b, d])
    open_channel(c, d, 'removed-member')
    carrier.wait(lambda: 'removed-member' in c.rejected)
    rejected(c, d, 'revoked-shared-invitation', cd_link)
    open_channel(c, d, 'cached-cookie', raw=True)
    c.request('restore_cookie', peer=d.booted['node'])
    d.request('restore_cookie', peer=c.booted['node'])
    assert c.request('accept', connection='cached-cookie') == {'error': 'unauthorized'}
    assert d.request('preauth_native', connection='cached-cookie', peer=c.booted['node']) == {
        'accepted': False, 'connected': False}
    print('PASS: remove-both fences both VMs cluster-wide; stale membership and shared invitation fail; surviving link remains usable', flush=True)
    print('PASS: even deliberately restored old OTP cookies and retained OTP allow-list entries cannot bypass carrier authorization', flush=True)

    connect(c, b, 'cb-readmit', invitation(c))
    connect(a, b, 'ab-readmit')
    assert b.request('exercise', peer=c.booted['node'])['remote_execution']
    chat_group([a, b, c])
    chat(b, [a, b, c], 'Freshly invited node rejoins chat', excluded=[d])
    print('PASS: a fresh invitation readmits a removed node without any permanent banned-device register', flush=True)

    pre_handover_link = invitation(b)
    a.request('remove_both', target=c.booted['id'])
    carrier.wait(lambda: membership(b) == {b.booted['id']})
    carrier.wait(lambda: not b.request('status')['connected'])
    assert b.request('status')['policy']['authority'] == b.booted['node']
    assert invitation(b).startswith('parvi://cluster/v1?')
    chat_group([b])
    chat(b, [b], 'Singleton survivor', excluded=[a, c, d])
    print('PASS: removing the admission actor\'s host moves authority to a surviving VM; invitations still work', flush=True)

    d.request('retire')
    connect(b, d, 'bd-final', pre_handover_link)
    assert b.request('exercise', peer=d.booted['node'])['remote_execution']
    chat_group([b, d])
    chat(d, [b, d], 'Chat after authority handover', excluded=[a, c])
    outage_link = invitation(b)
    assert b.request('stop_authority') is True
    rejected(b, a, 'authority-outage', outage_link)
    assert b.request('exercise', peer=d.booted['node'])['remote_execution']
    chat(b, [b, d], 'Existing chat survives admission outage', excluded=[a, c])
    print('PASS: admission-actor outage denies new joins without stopping existing native traffic', flush=True)
    assert d.request('stop_trust') is True
    carrier.wait(lambda: not d.request('status')['connected'], timeout=3)
    carrier.wait(lambda: not b.request('status')['connected'])
    chat_group([b])
    chat(b, [b], 'Disconnected process group pruned', excluded=[a, c, d])
    print('PASS: even normal trust-manager termination closes native controllers; no stale authorization survives', flush=True)
finally:
    for p in carrier.probes:
        p.close()
