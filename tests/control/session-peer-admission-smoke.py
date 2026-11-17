"""Joining needs only the link and whoever is present; no apps.

The creator delegates `grant`, then goes offline. A delegated grant holder's
policy is accepted by a newcomer through the delegation certificate chain.
Devices that arrive at an empty Session participate without privileges and
discover each other. Leaving and returning alone keeps a privilege.
"""
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
control=load('control',HERE/'buffee-control-smoke.py')
relay=load('relay',HERE.parent/'ReceptionDesk/relay-smoke.py')
relay.ERL=Path(shutil.which('erl'))
ADMIN={'grant','on_air','end_session'}

def main():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    paths=list((control.ROOT/'builds/intermediates/control/default/lib').glob('*/ebin'))
    output=control.ROOT/'builds/intermediates/buffee-control-check';output.mkdir(parents=True,exist_ok=True)
    subprocess.run([shutil.which('erlc'),'-Werror','-o',str(output),str(HERE/'ba_buffee_control_probe.erl')],check=True)
    paths=[output,*paths];runtimes=[];desk=None
    with tempfile.TemporaryDirectory() as state:
        def runtime(name,seed=None):
            r=control.Runtime(paths,seed=seed,state=str(Path(state)/name));runtimes.append(r);return r
        def member(r):return r.request('snapshot')['membership']
        def joined(r,link):
            assert r.request('join',invitation=link,desk=url)['ok']
            control.wait(r,lambda s:s['membership']['state']=='authorized')
        def meet(*rs):
            for r in rs:
                others={o.identity['id'] for o in rs if o is not r}
                control.wait(r,lambda s:others<=set(s['membership']['participants']))
        def same_policy(*rs):
            control.wait(rs[0],lambda s:all(member(o)['revision']==s['membership']['revision'] for o in rs[1:]))
        try:
            desk=relay.start_desk(port);url=f'ws://127.0.0.1:{port}/relay/v1'
            a=runtime('creator');assert a.request('create',desks=[url])['ok']
            link=a.request('invite')['value'];session=member(a)['buffee']
            assert '/v5?' in link
            b,c=runtime('b'),runtime('c')
            for r in (b,c):joined(r,link)
            meet(a,b,c)
            for r in (b,c):assert not ADMIN&set(member(r)['privileges'])
            assert a.request('grant_privilege',peer=b.identity['id'],privilege='grant')['ok']
            same_policy(a,b,c)
            assert 'grant' in member(b)['privileges']
            # The creator leaves; the delegated grant holder administers alone.
            # The probe halts without telling anyone, like a crash: lookups notice.
            a.close()
            for r in (b,c):control.wait(r,lambda s:a.identity['id'] not in s['membership']['participants'])
            assert b.request('grant_privilege',peer=c.identity['id'],privilege='on_air')['ok']
            same_policy(b,c);assert 'on_air' in member(c)['privileges']
            # A newcomer that never met the creator trusts b through the certificate chain.
            d=runtime('d');joined(d,link);meet(b,c,d);same_policy(b,c,d)
            view=member(d)
            assert b.identity['id'] in view['grant_holders'],view
            assert not ADMIN&set(view['privileges']),view
            # Everyone leaves. Arrivals at the empty Session participate without
            # privileges, keep its ID and find each other through Reception.
            c_seed=c.seed
            for r in (b,c,d):r.close()
            e,f=runtime('e'),runtime('f')
            joined(e,link)
            assert member(e)['buffee']==session and member(e)['participants']==[]
            joined(f,link);meet(e,f)
            for r in (e,f):assert not ADMIN&set(member(r)['privileges'])
            # c returns: its saved policy restores on_air without a grant holder present.
            c=runtime('c',c_seed);joined(c,link);meet(c,e,f)
            assert 'on_air' in member(c)['privileges']
            same_policy(c,e,f)
            for r in (e,f):assert c.identity['id'] in member(r)['members']
            print('PASS: v5 link; pairwise admission without a hub; vanished Device pruned; creator offline; delegated grant accepted by a newcomer; '
                  'empty Session keeps its ID and grants nothing; returning Device keeps on_air')
        finally:
            for r in runtimes:r.close()
            if desk:
                desk.terminate()
                try:desk.wait(timeout=5)
                except subprocess.TimeoutExpired:desk.kill();desk.wait()
if __name__=='__main__':main()
