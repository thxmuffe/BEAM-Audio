"""Ephemeral membership through two independent Desk service instances; no apps."""
import importlib.util
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path
HERE = Path(__file__).resolve().parent

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module
control=load('control',HERE/'session-control-smoke.py')
relay=load('relay',HERE.parent/'ReceptionDesk/local_reception.py')
relay.ERL=Path(shutil.which('erl'))

def main():
    ports=[]
    for _ in range(2):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));ports.append(sock.getsockname()[1])
    desks,runtimes=[],[]
    paths=list((control.ROOT/'builds/intermediates/control/default/lib').glob('*/ebin'))
    output=control.ROOT/'builds/intermediates/session-control-check';output.mkdir(parents=True,exist_ok=True)
    subprocess.run([shutil.which('erlc'),'-Werror','-o',str(output),str(HERE/'ba_session_control_probe.erl')],check=True)
    paths=[output,*paths]
    with tempfile.TemporaryDirectory() as state:
        def runtime(name,seed=None):
            r=control.Runtime(paths,seed=seed,state=str(Path(state)/name));runtimes.append(r);return r
        def authorized(r,revision=None):
            return control.wait(r,lambda s:s['membership']['state']=='authorized' and
                (revision is None or s['membership']['revision']==revision))
        def sync(a,*members):
            revision=a.request('snapshot')['membership']['revision']
            for r in members: authorized(r,revision)
        def present(a,b):
            # Each pair discovers and proves the link independently.
            for r,peer in ((a,b),(b,a)):
                control.wait(r,lambda s:peer.identity['id'] in s['membership']['participants'])
        def connect(a,b):
            present(a,b)
            if b.identity['id'] not in a.request('snapshot')['links']:
                reply=a.request('connect',peer=b.identity['id']);assert reply.get('ok'),reply
            for r,peer in ((a,b),(b,a)):
                control.wait(r,lambda s:s['links'].get(peer.identity['id'],{}).get('stage')=='authorized')
        try:
            desks.extend(relay.start_desk(p) for p in ports)
            urls=[f'ws://127.0.0.1:{p}/relay/v1' for p in ports]
            a=runtime('authority');assert a.request('create',desks=urls)['ok']
            control.wait(a,lambda s:all(d['connected'] for d in s['relay']['desks'].values()))
            original=a.request('snapshot')['membership'];members=[]
            invitation=a.request('invite')['value']
            for i in range(2):
                r=runtime(f'member{i}')
                assert r.request('join',invitation=invitation,desk=urls[i])['ok']
                authorized(r);members.append(r)
            x,y=members;sync(a,x,y)
            # Leaving does not consume the shared invitation either.
            assert y.request('leave_session')['ok']
            control.wait(a,lambda s:all(y.identity['id'] not in d.get('online',[]) for d in s['relay']['desks'].values()))
            # Presence ends with Leave; the link and any privileges remain.
            control.wait(a,lambda s:y.identity['id'] not in s['membership']['participants'])
            assert y.request('join_session',invitation=invitation)['ok']
            authorized(y);sync(a,x,y);connect(x,y)
            # Joined Devices hold the default rights (ba_session_membership:defaults/0).
            assert x.request('read',peer=y.identity['id'])['ok']
            for r in members:
                assert a.request('grant',peer=r.identity['id'],permissions=['capabilities_read','status_read'])['ok']
            sync(a,x,y);connect(x,y)
            assert x.request('read',peer=y.identity['id'])['ok']
            assert y.request('read',peer=x.identity['id'])['ok']
            # A single Desk worker or service failure cannot cascade into core
            # owners, links or the other Desk.
            connect(a,y)
            identities=[r.request('backend_ids') for r in (a,x,y)]
            for _ in range(3):
                assert a.request('desk_crash',desk=urls[0])['ok']
                control.wait(a,lambda s:s['relay']['desks'][urls[0]]['connected'])
            desks[0].kill();desks[0].wait(timeout=5)
            time.sleep(.5)
            assert x.request('read',peer=y.identity['id'])['ok']
            for r,old in zip((a,x,y),identities):assert r.request('backend_ids')==old
            desks[0]=relay.start_desk(ports[0])
            control.wait(a,lambda s:s['relay']['desks'][urls[0]]['connected'])
            control.wait(x,lambda s:s['relay']['desks'][urls[0]]['connected'])
            old_id = x.identity['id']
            connect(a, x)
            assert a.request('revoke',peer=old_id)['ok']
            control.wait(x,lambda s:s['membership']['state']=='revoked');sync(a,y)
            assert 'error' in x.request('connect',peer=y.identity['id'])
            # Forwardability must not let a removed identity bypass revocation.
            assert x.request('leave_session')['ok']
            assert x.request('join_session',invitation=invitation)['ok']
            control.wait(x,lambda s:s['membership']['state']=='revoked')
            # Address book (contacts): saving contact works locally on y without sync
            assert y.request('put_contact',id=a.identity['id'],name='Owner')['ok']
            assert y.request('put_contact',id=old_id,name='FormerPeer')['ok']
            assert y.request('group_contacts',name='Friends',ids=[a.identity['id'],old_id])['ok']
            contacts = y.request('list_contacts')
            assert a.identity['id'] in contacts['contacts'] and old_id in contacts['contacts']
            assert 'Friends' in contacts['groups']
            # Ephemeral session end: Owner departure terminates gathering; contacts persist
            x.close()
            assert a.request('end_session')['ok']
            end=time.monotonic()+15
            for r in (a,y):
                while True:
                    lifecycle=r.request('lifecycle')
                    if lifecycle['session']=={'state':'idle'}:
                        # Desk sockets are shared by the Device and outlive one Session.
                        assert lifecycle['live']==[] and not lifecycle['transient_state'],lifecycle
                        break
                    assert time.monotonic()<end,lifecycle
                    time.sleep(.1)
            y_seed=y.seed;y.close();y=runtime('member1',y_seed)
            retained_contacts = y.request('list_contacts')
            assert a.identity['id'] in retained_contacts['contacts']
            assert 'Friends' in retained_contacts['groups']
            print('PASS: shared invitation admits distinct Devices; leave/rejoin; revoked identity denied; two independent Desks, one Owner/Session; capability-limited messages; explicit grants; Desk failure isolation; revocation; ephemeral teardown; contacts preserved; no OTP distribution or apps')
        finally:
            for r in runtimes:r.close()
            for d in desks:
                d.terminate()
                try:d.wait(timeout=5)
                except subprocess.TimeoutExpired:d.kill();d.wait()
if __name__=='__main__':main()
