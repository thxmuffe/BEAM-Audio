"""Authenticated clock and revisioned Offset through two independent Desks; no apps."""
import concurrent.futures
import argparse
import importlib.util
import shutil
import socket
import subprocess
import time
from pathlib import Path
HERE=Path(__file__).resolve().parent

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
control=load('control',HERE/'swarm-control-smoke.py')
relay=load('relay',HERE.parent/'ReceptionDesk/relay-smoke.py');relay.ERL=Path(shutil.which('erl'))

def clock(r,predicate,timeout=20):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        s=r.request('clock_snapshot')
        if predicate(s):return s
        time.sleep(.025)
    raise AssertionError('Clock did not converge: '+str(s))

def ready(r):return clock(r,lambda s:s['state']=='synchronized' and s['offset_policy']['ready'])
def policy(r,revision):return clock(r,lambda s:s['offset_policy']['ready'] and s['offset_policy']['revision']==revision)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--production-cadence',action='store_true',help='Acquire the default 20x5s window across the 60s session renewal')
    args=parser.parse_args()
    root=control.ROOT;paths=list((root/'builds/intermediates/control/default/lib').glob('*/ebin'))
    out=root/'builds/intermediates/swarm-control-check';out.mkdir(parents=True,exist_ok=True)
    subprocess.run([shutil.which('erlc'),'-Werror','-o',str(out),str(HERE/'ba_swarm_control_probe.erl')],check=True)
    ports=[]
    for _ in range(2):
        with socket.socket() as sock:sock.bind(('127.0.0.1',0));ports.append(sock.getsockname()[1])
    desks=[];runtimes=[]
    try:
        desks.extend(relay.start_desk(p) for p in ports)
        urls=[f'ws://127.0.0.1:{p}/relay/v1' for p in ports]
        a,b,c=[control.Runtime([out,*paths]) for _ in range(3)];runtimes.extend((a,b,c))
        if not args.production_cadence:
            for r in runtimes:assert r.request('clock_prepare',interval_ms=100,samples=3)['ok']
        assert a.request('create',desks=urls)['ok']
        control.wait(a,lambda s:all(d['connected'] for d in s['relay']['desks'].values()))
        for i,r in enumerate((b,c)):
            assert r.request('join',invitation=a.request('invite')['value'],desk=urls[i])['ok']
            control.wait(r,lambda s:s['membership']['state']=='authorized')
            assert r.request('clock_snapshot')['state']!='synchronized','membership must not imply time access'
        assert a.request('grant',peer=b.identity['id'],permissions=['offset_write','time_read'])['ok']
        assert a.request('grant',peer=c.identity['id'],permissions=['time_read'])['ok']
        if args.production_cadence:
            start=time.monotonic()
            states=[clock(r,lambda s:s['state']=='synchronized' and s['offset_policy']['ready'],120) for r in runtimes]
            assert time.monotonic()-start>=90,'Production window was not exercised'
            assert all(s['sample_interval_ms']==5000 and s['filter_required_samples']==20 for s in states)
            assert all(s['filter_sample_count']==20 for s in states[1:]),states
            assert len({s['timeline'] for s in states})==1
            assert all(r.request('snapshot')['nodes']==[] for r in runtimes)
            print('PASS: production 20x5s clock acquisition across 60s control-session renewal; same reference, no OTP distribution or apps')
            return
        states=[ready(r) for r in runtimes]
        timeline=states[0]['timeline'];assert all(s['timeline']==timeline for s in states)
        assert all(s['offset_policy']['offset_ms']==1000 for s in states)
        assert b.request('clock_reference')=={'error':'authority_reference_only'}
        assert c.request('offset_set',offset_ms=1200,revision=1)=={'error':'forbidden'}
        assert a.request('clock_snapshot')['offset_policy']['revision']==1
        assert b.request('offset_set',offset_ms=250,revision=1)['ok']
        for r in runtimes:assert policy(r,2)['offset_policy']['offset_ms']==250
        assert b.request('offset_set',offset_ms=400,revision=1)=={'error':'conflict'}
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            changes=list(pool.map(lambda pair:pair[0].request('offset_set',offset_ms=pair[1],revision=2),[(a,600),(b,700)]))
        assert sum(bool(r.get('ok')) for r in changes)==1,changes
        assert sum(r.get('error')=='conflict' for r in changes)==1,changes
        values=[policy(r,3)['offset_policy']['offset_ms'] for r in runtimes];assert len(set(values))==1
        old=b.request('clock_snapshot')['instance']
        restarted=b.request('clock_restart');assert restarted['ok']
        assert not restarted['initial']['offset_policy']['ready'] and restarted['initial']['filter_sample_count']==0
        fresh=ready(b);assert fresh['instance']!=old and fresh['timeline']==timeline
        assert fresh['offset_policy']['revision']==3
        # Control-owner replacement drops all live sessions; the clock reauthenticates to its pinned authority.
        assert b.request('control_reset')['ok']
        fresh=ready(b);assert fresh['timeline']==timeline and fresh['offset_policy']['revision']==3
        assert a.request('clock_restart')['ok']
        root_state=ready(a);assert root_state['timeline']!=timeline and root_state['offset_policy']['revision']==3
        for r in (b,c):
            s=clock(r,lambda s:s['state']=='synchronized' and s['timeline']==root_state['timeline'] and s['offset_policy']['ready'])
            assert s['filter_sample_count']>=3 and s['offset_policy']['offset_ms']==values[0]
        snapshots=[r.request('snapshot') for r in runtimes]
        assert all(s['node']=='nonode@nohost' and s['nodes']==[] and not s['legacy_started'] for s in snapshots)
        print('PASS: signed four-timestamp clock across two Desks; zero-grant and unauthorized Offset rejection; single-writer compare-and-set and broadcast; retained Offset after clock restart; fresh filter after reference incarnation change; control-session recovery; no OTP distribution, apps or hardware timing claim')
    finally:
        for r in runtimes:r.close()
        for d in desks:d.terminate();d.wait(timeout=5)
if __name__=='__main__':main()
