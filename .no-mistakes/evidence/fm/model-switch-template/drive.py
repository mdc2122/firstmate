import os, pathlib, subprocess as s, time, json, threading, http.server
R=pathlib.Path.cwd(); L=R/'.test-switch-lab'; H=L/'home'; W=H/'wt'; W.mkdir(exist_ok=True)
E={'PATH':os.environ['PATH'],'HOME':str(H),'TERM':'xterm-256color','LANG':'en_US.UTF-8','TMPDIR':str(L/'tmp'),'PI_CODING_AGENT_DIR':str(H/'.omp/agent'),'OMP_SKIP_SETUP':'1','FM_HOME':str(H/'fm'),'FM_CONTROL_SWITCH_WAIT':'3'}
SOCK='./s'; real=s.check_output(['which','tmux'],text=True).strip(); shim=L/'shim'; shim.mkdir(exist_ok=True); (shim/'tmux').write_text('#!/bin/sh\nexec '+real+' -S '+SOCK+' -u "$@"\n'); (shim/'tmux').chmod(0o755); E['PATH']=str(shim)+':'+E['PATH']
def run(args,ok=True):
 p=s.run(list(map(str,args)),env=E,cwd=W,text=True,errors='replace',stdout=s.PIPE,stderr=s.STDOUT)
 if ok and p.returncode: raise Exception(p.stdout)
 return p
class API(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  req=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  body={'id':'chatcmpl-disposable','object':'chat.completion','created':int(time.time()),'model':req['model'],'choices':[{'index':0,'message':{'role':'assistant','content':'pong'},'finish_reason':'stop'}],'usage':{'prompt_tokens':10,'completion_tokens':1,'total_tokens':11}}
  self.send_response(200); self.send_header('Content-Type','text/event-stream' if req.get('stream') else 'application/json'); self.end_headers()
  if req.get('stream'):
   for delta,finish in [({'role':'assistant','content':'pong'},None),({},'stop')]:
    chunk={'id':'chatcmpl-disposable','object':'chat.completion.chunk','created':int(time.time()),'model':req['model'],'choices':[{'index':0,'delta':delta,'finish_reason':finish}]}
    self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode())
   self.wfile.write(b'data: [DONE]\n\n')
  else:self.wfile.write(json.dumps(body).encode())
 def log_message(self,*a):pass
server=http.server.HTTPServer(('127.0.0.1',18764),API); threading.Thread(target=server.serve_forever,daemon=True).start()
for args in [['git','init','-q'],['git','-c','user.email=t@t','-c','user.name=t','commit','-q','--allow-empty','-m','init']]:run(args)
F=H/'fm'; (F/'state').mkdir(parents=True,exist_ok=True); (F/'data/t1').mkdir(parents=True,exist_ok=True); (F/'data/t1/brief.md').write_text('brief\n')
epoch=int(time.time()); meta=F/'state/t1.meta'
meta.write_text(f'window=lab:fm-t1\nendpoint_task_id=t1\nworktree={W}\nproject={W}\nharness=omp\nkind=ship\nmodel=local-test/alpha\neffort=high\nspawn_gen=s{epoch}.123.456\n')
cmd='omp --config '+str(R/'.omp/fm-worker-overlay.yml')+' --model local-test/alpha --no-extensions --no-skills --no-rules --no-lsp --no-title --no-tools --cwd '+str(W)
run(['tmux','new-session','-d','-s','lab','-n','fm-t1','-x','200','-y','50','-c',W,cmd])
def pane():return run(['tmux','capture-pane','-p','-t','lab:fm-t1']).stdout
def wait(fn,n=60):
 for _ in range(n*2):
  if fn():return
  time.sleep(.5)
 (L/'blocked-pane.txt').write_text(pane()); print(run(['bash','-c',f'. "{R}/bin/fm-tmux-lib.sh"; set -x; fm_tmux_composer_state lab:fm-t1']).stdout[-8000:]); print(control('local-test/beta').stdout); raise Exception('timeout\n'+pane())
def empty():
 return run(['bash','-c',f'. "{R}/bin/fm-tmux-lib.sh"; fm_tmux_composer_state lab:fm-t1']).stdout.strip()=='empty'
def control(model,extra=[]):return run([R/'bin/fm-control.sh','t1','switch-model','--model',model,'--reason','disposable live acceptance',*extra],False)
log=[]
def record(label,p):
 text=f'### {label}\nexit={p.returncode}\n{p.stdout}'; print(text,flush=True); log.append(text)
try:
 time.sleep(8)
 gen=run([R/'bin/fm-busy-event.sh','arm',F/'state','t1','--state','idle','--source','fm-spawn','--event','seed']).stdout.strip(); meta.write_text(meta.read_text()+'busy_gen='+gen+'\n')
 p=control('local-test/beta'); record('Before first turn refusal',p); assert p.returncode
 run(['tmux','send-keys','-t','lab:fm-t1','-l','Reply with exactly pong']); time.sleep(.5); run(['tmux','send-keys','-t','lab:fm-t1','Enter'])
 sessions=H/'.omp/agent/sessions/-wt'; wait(lambda: bool(list(sessions.glob('*.jsonl')))); wait(empty); time.sleep(2)
 p=control('nosuch-provider/nosuch-model'); record('Unknown model refuses without notice',p); assert p.returncode and not (F/'state/t1.inbox').exists(); wait(empty)
 p=control('local-test/beta'); record('Confirmed in-place switch preserving high effort',p); assert p.returncode==0 and 'effort=high' in p.stdout
 msgs=list((F/'state/t1.inbox').glob('*.msg')); assert len(msgs)==1
 log.append('Persisted notice:\n'+msgs[0].read_text()); log.append('Durable task profile:\n'+meta.read_text())
 p=control('local-test/beta'); record('Already-running no-op sends no duplicate',p); assert p.returncode and len(list((F/'state/t1.inbox').glob('*.msg')))==1
 # Ambiguity and dead-history attempts use disposable session records with real running endpoint.
 sf=next(sessions.glob('*.jsonl')); other=sessions/'ambiguous.jsonl'; other.write_bytes(sf.read_bytes())
 p=control('local-test/alpha'); record('Ambiguous current records refuse',p); assert p.returncode and 'no unique omp session' in p.stdout; other.unlink()
 os.utime(sf,(epoch-20,epoch-20)); p=control('local-test/alpha'); record('Historical-only record refuses rather than claiming already running',p); assert p.returncode and 'no unique omp session' in p.stdout
 os.utime(sf,None)
 (L/'pane.txt').write_text(pane()); (L/'session.jsonl').write_bytes(sf.read_bytes())
finally:
 (L/'live.log').write_text('\n\n'.join(log)); run(['tmux','kill-server'],False); server.shutdown()
