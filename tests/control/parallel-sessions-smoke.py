"""Two concurrent Sessions per Device through one local Reception connection.
Run after rebar3 compile at the core root. Uses disposable keys and state.
"""
from pathlib import Path
import subprocess,os,json,tempfile,socket,importlib.util,shutil,time,queue,threading
core=Path(__file__).resolve().parents[2]
output=core/'builds/intermediates/session-check';output.mkdir(parents=True,exist_ok=True)
subprocess.run([shutil.which('erlc'),'-Werror','-o',str(output),str(core/'tests/control/ba_sessions_probe.erl')],check=True)
spec=importlib.util.spec_from_file_location('relay',core/'tests/ReceptionDesk/relay-smoke.py');relay=importlib.util.module_from_spec(spec);spec.loader.exec_module(relay);relay.ERL=Path(shutil.which('erl'))
class Device:
 def __init__(self,state,seed):
  self.q=queue.Queue();self.p=subprocess.Popen(['erl','+S','2','-noshell','-pa',str(output),*map(str,(core/'builds/intermediates/erlang/default/lib').glob('*/ebin')),'-s','ba_sessions_probe','main'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(os.environ,BA_STATE_DIR=state,BA_IDENTITY_SEED=seed))
  def read():
   for line in self.p.stdout:
    try:self.q.put(json.loads(line))
    except:pass
  threading.Thread(target=read,daemon=True).start()
 def req(self,method,**kwargs):
  self.p.stdin.write(json.dumps(dict(method=method,**kwargs))+'\n');self.p.stdin.flush();r=self.q.get(timeout=28);assert not r.get('error'),r;return r
 def wait(self,slot,test):
  deadline=time.monotonic()+22
  while time.monotonic()<deadline:
   r=self.req('snapshot',session=slot)
   if test(r):return r
   time.sleep(.1)
  raise AssertionError(r)
 def close(self):
  if self.p.poll() is None:self.p.stdin.close();self.p.wait(timeout=8)
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
desk=relay.start_desk(port);devices=[]
try:
 with tempfile.TemporaryDirectory() as state:
  a=Device(str(Path(state)/'a'),'14'*32);b=Device(str(Path(state)/'b'),'15'*32);devices=[a,b]
  url=f'ws://127.0.0.1:{port}/relay/v1';aslots=[];bslots=[];links=[]
  for name in ['One','Two']:
   aid='default' if name=='One' else a.req('new_session')['session_id'];aslots.append(aid)
   ra=a.req('create_buffee',session=aid,name=name,desks=[url])
   if aid!='default':assert ra['buffee']['buffee']==aid
   a.wait(aid,lambda s:s['desks']['desks'][url]['connected'])
   link=a.req('invitation',session=aid)['result'];links.append(link)
   bid=b.req('new_session')['session_id']
   b.req('capability',session=bid,capability='microphone',enabled=True)
   rb=b.req('join_buffee',session=bid,invitation=link);bid=rb['session_id'];bslots.append(bid)
   assert b.wait(bid,lambda s:s['buffee']['state']=='authorized')['consent']['microphone']
   a.wait(aid,lambda s:len(s['devices'])==2 and all(d['state']=='authorized' for d in s['devices']))
   b.wait(bid,lambda s:len(s['devices'])==2 and all(d['state']=='authorized' for d in s['devices']))
  assert a.req('snapshot',session=aslots[0])['device']==a.req('snapshot',session=aslots[1])['device']
  assert a.req('connections')['count']==b.req('connections')['count']==1
  print('PASS: two concurrent Buffees, shared Device identity and one authenticated socket per Device',flush=True)
  a.req('send',session=aslots[0],text='Only One')
  b.wait(bslots[0],lambda s:any(m['text']=='Only One' for m in s['messages']))
  assert not any(m['text']=='Only One' for m in b.req('snapshot',session=bslots[1])['messages'])
  a.req('capability',session=aslots[0],capability='microphone',enabled=True)
  assert not a.req('snapshot',session=aslots[1])['consent']['microphone']
  a.req('close_session',session=aslots[0]);assert a.req('connections')['count']==1
  a.req('send',session=aslots[1],text='Two still works')
  b.wait(bslots[1],lambda s:any(m['text']=='Two still works' for m in s['messages']))
  print('PASS: chat and consent isolation; closing one tab preserves delivery in another',flush=True)
  new=a.req('new_session')['session_id'];ra=a.req('join_buffee',session=new,invitation=links[0]);assert ra['session_id']==aslots[0];a.wait(aslots[0],lambda s:s['buffee']['role']=='owner')
  print('PASS: closed owner returns through its invitation with saved ownership',flush=True)
  a.close();a=Device(str(Path(state)/'a'),'14'*32);devices.append(a)
  a.wait(aslots[0],lambda s:s['buffee'].get('role')=='owner');a.wait(aslots[1],lambda s:s['buffee'].get('role')=='owner')
  assert a.req('connections')['count']==1
  print('PASS: both open Sessions restore after full runtime restart')
finally:
 for device in devices:device.close()
 desk.terminate();desk.wait(timeout=8)
