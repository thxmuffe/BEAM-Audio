"""Three real local Devices: requested privileges, shared grant, return and End."""
import importlib.util
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

control = load('control', HERE / 'buffee-control-smoke.py')
relay = load('relay', HERE.parent / 'ReceptionDesk/local_reception.py')
relay.ERL = Path(shutil.which('erl'))

def main():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    output = control.ROOT / 'builds/intermediates/buffee-control-check'
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([shutil.which('erlc'), '-Werror', '-o', str(output), str(HERE / 'ba_buffee_control_probe.erl')], check=True)
    paths = [output, *(control.ROOT / 'builds/intermediates/control/default/lib').glob('*/ebin')]
    devices = []
    desk = relay.start_desk(port)
    try:
        with tempfile.TemporaryDirectory() as state:
            def device(name, seed=None):
                d = control.Runtime(paths, seed=seed, state=str(Path(state) / name))
                devices.append(d)
                return d
            NAMED = {'grant', 'on_air', 'end_session'}
            def holds(d, *wanted):
                return control.wait(d, lambda s: s['membership']['state'] == 'authorized'
                                    and NAMED & set(s['membership']['privileges']) == set(wanted))
            def revision(d, rev):
                return control.wait(d, lambda s: s['membership']['revision'] == rev)
            def clocks(*ds):
                started=time.monotonic();deadline=started+10;trace=[]
                def view(d):
                    c=d.request('clock_snapshot');return (c['state'],c['role'],str(c.get('master'))[:6],c.get('filter_reset_reason'),c.get('filter_sample_count'))
                while not all(d.request('clock_snapshot')['state']=='synchronized' for d in ds):
                    v=[view(d) for d in ds]
                    if not trace or trace[-1][1]!=v:trace.append((round(time.monotonic()-started,1),v))
                    # On failure: final clocks, membership views and the state timeline.
                    assert time.monotonic()<deadline, ([(d.identity["id"][:8],d.request("clock_snapshot"),
                        {k:d.request('snapshot')['membership'].get(k) for k in ('privileges','participants','state','revision')}) for d in ds],trace)
                    time.sleep(.05)
            def told(d, subject, text):
                # Info entries are derived locally by every Device, never sent.
                deadline=time.monotonic()+10
                while not any(m.get('level')=='info' and m['sender']==subject.identity['id'] and m['text']==text for m in d.request('chat_history')):
                    assert time.monotonic()<deadline, (text, d.request('chat_history'))
                    time.sleep(.05)
            url = f'ws://127.0.0.1:{port}/relay/v1'
            a = device('creator')
            a.request('clock_prepare',interval_ms=1000,samples=2)
            assert a.request('create', desks=[url])['ok']
            control.wait(a, lambda s: s['relay']['desks'][url]['connected'])
            holds(a, 'grant', 'on_air', 'end_session')
            invitation = a.request('invite')['value']
            b, c = device('second'), device('third')
            for d in (b, c):
                d.request('clock_prepare',interval_ms=1000,samples=2)
                assert d.request('join', invitation=invitation, desk=url)['ok']
                holds(d)
                # Requests go to grant holders this Device is paired with now.
                control.wait(d, lambda s: a.identity['id'] in s['membership']['participants'])
            # Every privilege is requested; a grant holder answers.
            assert b.request('request_privilege',privilege='on_air')['ok']
            control.wait(a,lambda s: s['membership']['requests'].get(b.identity['id']) == ['on_air'])
            # Both the asking Device and the one that can answer see the request in chat.
            told(a, b, 'asks to go on air'); told(b, b, 'asks to go on air')
            assert a.request('decline_privilege',peer=b.identity['id'],privilege='on_air')['ok']
            assert b.identity['id'] not in a.request('snapshot')['membership']['requests']
            assert c.request('decline_privilege',peer=b.identity['id'],privilege='on_air') == {'error': 'grant_required'}
            assert b.request('request_privilege',privilege='on_air')['ok']
            control.wait(a,lambda s: s['membership']['requests'].get(b.identity['id']) == ['on_air'])
            assert a.request('grant_privilege',peer=b.identity['id'],privilege='on_air')['ok']
            holds(b,'on_air')
            # Need-to-know: the grant holder and the Device concerned learn it; c does not.
            for d in (a, b): told(d, b, 'can now go on air')
            assert a.request('take_privilege',peer=b.identity['id'],privilege='on_air')['ok']
            holds(b)
            # Losing a privilege is debug-level: not in anyone's visible history.
            for d in (a, b, c): assert not any(m['text']=='can no longer go on air' for m in d.request('chat_history'))
            assert b.identity['id'] not in a.request('snapshot')['membership']['requests']
            # The grant holder's own policy answers on-air requests: no, then always.
            assert a.request('answer_on_air_requests',value='no')['ok']
            assert c.request('request_privilege',privilege='on_air')['ok']
            assert a.request('answer_on_air_requests',value='always')['ok']
            assert c.identity['id'] not in a.request('snapshot')['membership']['requests']
            assert c.request('request_privilege',privilege='on_air')['ok']
            holds(c,'on_air')
            assert a.request('take_privilege',peer=c.identity['id'],privilege='on_air')['ok']
            holds(c)
            assert a.request('answer_on_air_requests',value='ask')['ok']
            assert b.request('request_privilege',privilege='on_air')['ok']
            assert a.request('grant',peer=b.identity['id'],permissions=['stream_publish','time_read'])['ok']
            assert a.request('grant',peer=c.identity['id'],permissions=['time_read'])['ok']
            holds(b, 'on_air')
            assert b.request('end_buffee')=={'error':'end_privilege_required'}
            assert b.request('grant_privilege', peer=c.identity['id'], privilege='on_air') == {'error': 'grant_required'}
            assert a.request('grant_privilege', peer=b.identity['id'], privilege='grant')['ok']
            holds(b, 'grant', 'on_air')
            rev = a.request('snapshot')['membership']['revision']
            revision(c, rev)
            clocks(a, b, c)
            # A join is a new signed member, shown once; link presence is debug-only.
            told(a, b, 'joined the Session'); told(a, c, 'joined the Session')
            assert sum(m['text']=='joined the Session' and m['sender']==b.identity['id'] for m in a.request('chat_history'))==1
            assert not any(m['text'] in ('is here','is online') for d in (a, b, c) for m in d.request('chat_history'))
            timeline=b.request('clock_snapshot')['timeline']
            first_id, first_seed = a.identity['id'], a.seed
            assert a.request('leave_buffee')['ok']
            assert b.request('grant_privilege', peer=c.identity['id'], privilege='on_air')['ok']
            holds(c, 'on_air')
            clocks(b, c)
            assert b.request('clock_snapshot')['timeline']==timeline
            assert c.request('clock_snapshot')['timeline']==timeline
            # Giving up grant does not stop an on-air Device or its clock service.
            assert b.request('take_privilege',peer=b.identity['id'],privilege='grant')['ok']
            holds(b,'on_air')
            clocks(b, c)
            assert b.request('clock_snapshot')['timeline']==timeline
            # Reachability is Reception's report (refreshed every 2 s), not live pairing.
            control.wait(b, lambda s: not s['membership']['grant_holder_present'])
            assert b.request('start_runtime')['connection']['state']=='joined'
            a.close()
            a = device('creator', first_seed)
            assert a.identity['id'] == first_id
            a.request('start_app')
            holds(a, 'grant', 'on_air', 'end_session')
            control.wait(a, lambda s: s['membership']['revision'] == b.request('snapshot')['membership']['revision'])
            # The returning creator keeps its original Session identity.
            assert a.request('snapshot')['membership']['buffee'] == b.request('snapshot')['membership']['buffee']
            assert a.request('grant_privilege',peer=b.identity['id'],privilege='grant')['ok']
            holds(b,'grant','on_air')
            assert b.request('take_privilege', peer=first_id, privilege='grant')['ok']
            holds(a, 'on_air', 'end_session')
            assert a.request('take_privilege', peer=c.identity['id'], privilege='on_air') == {'error': 'grant_required'}
            # End is its own privilege: grant alone does not end, but a grant
            # holder's own request for it needs nobody else.
            assert b.request('end_buffee')=={'error':'end_privilege_required'}
            assert b.request('request_privilege',privilege='end_session')['ok']
            holds(b,'grant','on_air','end_session')
            rev = b.request('snapshot')['membership']['revision']
            revision(a, rev); revision(c, rev)
            assert b.request('end_buffee')['ok']
            for d in (a, b, c):
                deadline = time.monotonic() + 10
                while d.request('buffee_status') != {'state': 'idle'}:
                    assert time.monotonic() < deadline
                    time.sleep(.1)
            saved_seed=b.seed;b.close();b=device('second',saved_seed);b.request('start_app')
            assert b.request('buffee_status')=={'state':'idle'}
            print('PASS: requested privileges; shared grant; creator return; acquired clock continues with on-air Devices and no online grant holder; giving up grant; End needs its own privilege (software timing only)')
            # Stop the VMs before their state folder is removed (Windows keeps
            # open files locked, so cleanup would otherwise fail).
            for d in devices:
                d.close()
    finally:
        for d in devices:
            d.close()
        desk.terminate()
        desk.wait(timeout=5)

if __name__ == '__main__':
    main()
