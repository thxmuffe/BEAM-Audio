"""Live admitted peers retain grants after Captain loss; admission stays closed."""
import importlib.util
import shutil
import socket
import subprocess
import time
from pathlib import Path
HERE = Path(__file__).resolve().parent

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module
control = load('control', HERE/'swarm-control-smoke.py')
relay = load('relay', HERE.parent/'ReceptionDesk/relay-smoke.py')
relay.ERL = Path(shutil.which('erl'))

def main():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    output = control.ROOT/'builds/intermediates/frozen-authority-check'
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['erlc', '-Werror', '-o', str(output), str(HERE/'ba_swarm_control_probe.erl')], check=True)
    paths = [output, *list((control.ROOT/'builds/intermediates/control/default/lib').glob('*/ebin'))]
    desk = relay.start_desk(port); runtimes = []
    try:
        a, b, c = [control.Runtime(paths, extra_env={'BA_DEVICE_NAME': name}) for name in ('Host', 'Mac', 'Phone')]
        runtimes.extend([a, b, c])
        url = f'ws://127.0.0.1:{port}/relay/v1'
        assert a.request('create', desks=[url])['ok']
        invitation = a.request('invite')['value']
        for peer in (b, c):
            assert peer.request('join', invitation=invitation, desk=url)['ok']
            control.wait(peer, lambda s: s['membership']['state']=='authorized')
            assert a.request('grant', peer=peer.identity['id'], permissions=['capabilities_read', 'job_offer', 'status_read'])['ok']
        revision = a.request('snapshot')['membership']['revision']
        for peer in (b, c):
            control.wait(peer, lambda s: s['membership']['revision']==revision)
        assert b.request('connect', peer=c.identity['id'])['ok']
        for local, peer in ((b,c),(c,b)):
            control.wait(local, lambda s: s['sessions'].get(peer.identity['id'],{}).get('stage')=='authorized')
        assert 'error' in b.request('end_swarm')
        assert a.request('disconnect_app')['ok']  # App closure must not send End.
        for peer in (b,c):
            assert peer.request('expire_authority_presence')['ok']
            state = control.wait(peer, lambda s: s['membership']['authority_state']=='frozen')
            assert state['membership']['state']=='authorized'
            assert state['membership']['revision']==revision
        # Recreate a control owner after Captain loss: peers must authenticate
        # using retained grants, without requiring the Captain to renew them.
        assert b.request('control_reset')['ok']
        assert b.request('connect', peer=c.identity['id'])['ok']
        control.wait(b, lambda s: s['sessions'].get(c.identity['id'],{}).get('stage')=='authorized')
        assert b.request('read', peer=c.identity['id'])['ok']
        # A non-Captain coordinator still needs a local receiver Contract/consent.
        contract = 'D'*32
        assert c.request('enable_test')['ok']
        assert c.request('allow_jobs', director=b.identity['id'], contract=contract)['ok']
        offered = b.request('offer_job', peer=c.identity['id'], contract=contract, duration_ms=100, lease_ms=1000)
        assert offered['ok'], offered
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            job=b.request('job_status', id=offered['value'])
            if job.get('value',{}).get('state')=='completed': break
            time.sleep(.05)
        else: raise AssertionError(job)
        for local, peer in ((b,c),(c,b)):
            contacts = local.request('list_contacts')
            assert peer.identity['id'] in contacts['contacts']
            ids=contacts['groups']['Test gathering']
            assert peer.identity['id'] in ids and len(ids)==len(set(ids))
            snapshot=local.request('start_runtime')
            assert snapshot['connection']['state']=='authority_frozen'
        state_dir=a.state.name; seed=a.seed
        a.close()
        returned=control.Runtime(paths,seed=seed,state=state_dir,extra_env={'BA_DEVICE_NAME':'Host'})
        runtimes.append(returned)
        returned.request('start_app')
        recovered=control.wait(returned,lambda s:s['membership']['state']=='authorized' and s['membership']['role']=='authority')
        assert recovered['membership']['revision']>revision
        for member in (b,c):
            control.wait(member,lambda s:s['membership']['authority_state']=='available' and s['membership']['revision']==recovered['membership']['revision'])
        assert returned.request('invite')['value']==invitation
        assert returned.request('revoke',peer=c.identity['id'])['ok']
        control.wait(c,lambda s:s['membership']['state']=='revoked')
        latest=returned.request('snapshot')['membership']['revision']
        control.wait(b,lambda s:s['membership']['revision']==latest)
        returned.request('disconnect_app');returned.close()
        again=control.Runtime(paths,seed=seed,state=state_dir);runtimes.append(again)
        again.request('start_app')
        control.wait(again,lambda s:s['membership']['role']=='authority' and s['membership']['state']=='authorized')
        assert c.request('leave_swarm')['ok']
        assert c.request('join',invitation=invitation,desk=url)['ok']
        control.wait(c,lambda s:s['membership']['state']=='revoked')
        assert c.request('leave_swarm')['ok']
        assert again.request('end_swarm')['ok']
        for member in (b,c):
            deadline=time.monotonic()+5
            while member.request('swarm_status')['state']!='idle':
                assert time.monotonic()<deadline;time.sleep(.05)
        assert b.request('join',invitation=invitation,desk=url)['ok']
        fresh=control.wait(b,lambda s:s['membership']['state']=='authorized' and s['membership']['role']=='authority')
        assert fresh['membership']['members']==[b.identity['id']]
        assert fresh['membership']['revision']==1
        assert b.request('end_swarm')['ok']
        # The original Captain's old saved history alone cannot recover anything.
        assert again.request('start_runtime')['swarm']['state']=='idle'
        solo=control.Runtime(paths);runtimes.append(solo)
        assert solo.request('create',desks=[url])['ok']
        solo_dir=solo.state.name;solo_seed=solo.seed;solo.close()
        alone=control.Runtime(paths,seed=solo_seed,state=solo_dir);runtimes.append(alone)
        alone.request('start_app');time.sleep(.6)
        lonely=alone.request('snapshot')['membership']
        assert lonely['role']=='recovering' and lonely['state']!='authorized'
        assert 'error' in alone.request('invite')
        print('PASS: frozen grants support peer jobs; restart recovery requires a live admitted peer; explicit End tears down and first link reuse starts a fresh Captain; revoked Devices stay blocked after recovery; no-peer history cannot recover authority; contact/group collection deduplicates; no audio hardware.')
    finally:
        for runtime in runtimes: runtime.close()
        desk.terminate(); desk.wait(timeout=5)

if __name__ == '__main__': main()
