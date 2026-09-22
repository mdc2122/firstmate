import os,socketserver,threading,subprocess,json,time,hashlib
from pathlib import Path
root=Path.cwd();home=root/'.test-retry-deadline/home'
evidence=Path('/Users/Morley/.no-mistakes/evidence/01M33B4QRYNHNE1CQG8VDXWM3Z')
for p in ['data','state','config','projects']:(home/p).mkdir(parents=True,exist_ok=True)
(home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n- [ ] deadline-live - Live deadline https://github.com/mdc2122/firstmate/pull/8 (repo: firstmate) (kind: ship)\n')
env=os.environ.copy();env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),TMPDIR=str(root/'.test-retry-deadline'))
base=subprocess.run(['bin/fm-contributions.sh','poll'],env=env,text=True,capture_output=True,timeout=40)
record_path=home/'data/deadline-live/contributions.json'
before=record_path.read_bytes();record=json.loads(before)
assert base.returncode==0 and record['records'][0]['error'] is None and record['records'][0]['observation']['state']=='open'
log=[];start=time.monotonic();stop=threading.Event()
class Proxy(socketserver.BaseRequestHandler):
 def handle(self):
  data=b''
  while b'\r\n\r\n' not in data:
   part=self.request.recv(4096)
   if not part:return
   data+=part
  method,address,_=data.split(b'\r\n',1)[0].decode().split(' ')
  assert method=='CONNECT' and address=='api.github.com:443'
  log.append({'elapsed_seconds':round(time.monotonic()-start,3),'destination':address,'action':'hold CONNECT until poll completes; no fabricated forge response'})
  stop.wait(10)
class Server(socketserver.ThreadingTCPServer):daemon_threads=True
with Server(('127.0.0.1',0),Proxy) as server:
 threading.Thread(target=server.serve_forever,daemon=True).start()
 env.update(HTTPS_PROXY=f'http://127.0.0.1:{server.server_address[1]}',HTTP_PROXY=f'http://127.0.0.1:{server.server_address[1]}',NO_PROXY='',FM_CONTRIBUTIONS_BUDGET='2')
 result=subprocess.run(['bin/fm-contributions.sh','poll'],env=env,text=True,capture_output=True,timeout=15)
 elapsed=round(time.monotonic()-start,3);stop.set();server.shutdown()
after=record_path.read_bytes();wake=home/'state/.wake-queue'
report={'command':'FM_CONTRIBUTIONS_BUDGET=2 bin/fm-contributions.sh poll','baseline_poll_exit':base.returncode,'exit_code':result.returncode,'stdout':result.stdout,'stderr':result.stderr,'elapsed_seconds':elapsed,'connections':log,'record_unchanged':before==after,'before_sha256':hashlib.sha256(before).hexdigest(),'after_sha256':hashlib.sha256(after).hexdigest(),'wake_queue_empty':not wake.exists() or wake.stat().st_size==0,'persisted_record':json.loads(after)}
(evidence/'contribution-live-deadline.json').write_text(json.dumps(report,indent=2)+'\n')
assert log and result.returncode==0 and result.stdout=='' and result.stderr=='' and before==after and report['wake_queue_empty'] and elapsed<5
print(json.dumps({k:v for k,v in report.items() if k!='persisted_record'},indent=2))
