import os,socket,socketserver,select,threading,subprocess,json,time
from pathlib import Path
root=Path.cwd()
evidence=Path('/Users/Morley/.no-mistakes/evidence/01M33B4QRYNHNE1CQG8VDXWM3Z')
home=root/'.test-retry-tmp/proxy-home'
for p in ['data','state','config','projects']:(home/p).mkdir(parents=True,exist_ok=True)
(home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n- [ ] retry-proxy - Live network retry https://github.com/mdc2122/firstmate/pull/9 (repo: firstmate) (kind: ship)\n')
log=[];lock=threading.Lock();start=time.monotonic()
class Proxy(socketserver.BaseRequestHandler):
 def handle(self):
  data=b''
  while b'\r\n\r\n' not in data:
   part=self.request.recv(4096)
   if not part:return
   data+=part
  method,address,_=data.split(b'\r\n',1)[0].decode().split(' ')
  host,port=address.rsplit(':',1)
  assert method=='CONNECT' and host=='api.github.com' and port=='443'
  with lock:
   seq=len(log)+1
   reject=seq<=2
   log.append({'connection':seq,'elapsed_seconds':round(time.monotonic()-start,3),'destination':address,'action':'inject HTTP 502 before TLS' if reject else 'tunnel actual GitHub TLS'})
  if reject:
   self.request.sendall(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
   return
  with socket.create_connection((host,int(port)),timeout=10) as upstream:
   self.request.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
   while True:
    ready,_,_=select.select([self.request,upstream],[],[],15)
    if not ready:return
    for source in ready:
     chunk=source.recv(65536)
     if not chunk:return
     (upstream if source is self.request else self.request).sendall(chunk)
class Server(socketserver.ThreadingTCPServer):daemon_threads=True
with Server(('127.0.0.1',0),Proxy) as server:
 threading.Thread(target=server.serve_forever,daemon=True).start()
 env=os.environ.copy()
 env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),TMPDIR=str(root/'.test-retry-tmp'),HTTPS_PROXY=f'http://127.0.0.1:{server.server_address[1]}',HTTP_PROXY=f'http://127.0.0.1:{server.server_address[1]}',NO_PROXY='')
 result=subprocess.run(['bin/fm-contributions.sh','poll'],env=env,text=True,capture_output=True,timeout=40)
 server.shutdown()
record=json.loads((home/'data/retry-proxy/contributions.json').read_text())
report={'command':'bin/fm-contributions.sh poll','network_fault':'first two CONNECT connections receive HTTP 502; subsequent connections relay real GitHub TLS unchanged','exit_code':result.returncode,'stdout':result.stdout,'stderr':result.stderr,'connections':log,'persisted_record':record}
(evidence/'contribution-live-transient-retry.json').write_text(json.dumps(report,indent=2)+'\n')
assert result.returncode==0 and result.stdout=='' and result.stderr==''
assert len(log)>=3 and record['records'][0]['error'] is None and record['records'][0]['observation']['state']=='merged'
print(json.dumps({'exit_code':result.returncode,'connections':log,'error':record['records'][0]['error'],'state':record['records'][0]['observation']['state']},indent=2))
