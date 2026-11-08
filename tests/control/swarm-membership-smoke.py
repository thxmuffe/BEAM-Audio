"""Durable membership through two independent Desk service instances; no apps."""
import importlib.util
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module
control=load('control',HERE/'swarm-control-smoke.py')
relay=load('relay',HERE.parent/'ReceptionDesk/relay-smoke.py')
relay.ERL=Path(shutil.which('erl'))

def main():
    ports=[]
    for _ in range(2):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));ports.append(sock.getsockname()[1])
    desks,runtimes=[],[]
    paths=list((control.ROOT/'builds/intermediates/control/default/lib').glob('*/ebin'))
    output=control.ROOT/'builds/intermediates/swarm-control-check';output.mkdir(parents=True,exist_ok=True)
    subprocess.run([shutil.which('erlc'),'-Werror','-o',str(output),str(HERE/'parvi_swarm_control_probe.erl')],check=True)
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
        def connect(a,b):
            assert a.request('connect',peer=b.identity['id'])['ok']
            for r,peer in ((a,b),(b,a)):
                control.wait(r,lambda s:s['sessions'].get(peer.identity['id'],{}).get('stage')=='authorized')
        try:
            desks.extend(relay.start_desk(p) for p in ports)
            urls=[f'ws://127.0.0.1:{p}/relay/v1' for p in ports]
            a=runtime('authority');assert a.request('create',desks=urls)['ok']
            control.wait(a,lambda s:all(d['connected'] for d in s['relay']['desks'].values()))
            original=a.request('snapshot')['membership'];members=[]
            for i in range(2):
                r=runtime(f'member{i}');invitation=a.request('invite')['value']
                assert r.request('join',invitation=invitation,desk=urls[i])['ok']
                authorized(r);members.append(r)
            x,y=members;sync(a,x,y);connect(x,y)
            assert x.request('read',peer=y.identity['id'])=={'error':'forbidden'}
            for r in members:
                assert a.request('grant',peer=r.identity['id'],permissions=['capabilities_read','status_read'])['ok']
            sync(a,x,y);connect(x,y)
            assert x.request('read',peer=y.identity['id'])['ok']
            assert y.request('read',peer=x.identity['id'])['ok']
            old_id,seed=x.identity['id'],x.seed;x.close();x=runtime('member0',seed)
            assert x.identity['id']==old_id
            assert x.request('resume',desk=urls[1])['ok']
            authorized(x);sync(a,x,y);connect(x,y)
            assert x.request('read',peer=y.identity['id'])['ok']
            connect(a,x)
            contract='C'*32
            assert x.request('enable_test')['ok']
            assert x.request('allow_jobs',director=a.identity['id'],contract=contract)['ok']
            job=a.request('offer_job',peer=old_id,contract=contract,duration_ms=10000,lease_ms=10000)['value']
            control.job_state(a,job,'accepted')
            assert a.request('revoke',peer=old_id)['ok']
            control.wait(x,lambda s:s['workers']==0 and s['worker_outcomes'][0]=='session_lost')
            control.wait(x,lambda s:s['membership']['state']=='revoked');sync(a,y)
            assert 'error' in x.request('connect',peer=y.identity['id'])
            x.close();a_seed=a.seed;a.close();a=runtime('authority',a_seed)
            assert a.request('create',desks=urls)['ok']
            resumed=a.request('snapshot')['membership']
            assert resumed['swarm']==original['swarm'] and resumed['epoch']==original['epoch']+1
            x=runtime('member0',seed);assert x.request('resume',desk=urls[0])['ok']
            control.wait(x,lambda s:s['membership']['state']=='revoked')
            y_seed=y.seed;y.close();y=runtime('member1',y_seed)
            assert y.request('resume',desk=urls[0])['ok']
            authorized(y);sync(a,y);connect(a,y)
            assert y.request('read',peer=a.identity['id'])['ok']
            print('PASS: two independent Desks, one authority/Swarm; Passport alone denies operations; explicit grants; cross-Desk status; durable alternate-Desk rejoin; authority restart; revoked Passport rejected after both restarts; no OTP distribution or apps')
        finally:
            for r in runtimes:r.close()
            for d in desks:
                d.terminate()
                try:d.wait(timeout=5)
                except subprocess.TimeoutExpired:d.kill();d.wait()
if __name__=='__main__':main()
