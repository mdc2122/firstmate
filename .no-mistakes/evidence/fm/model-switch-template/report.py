import pathlib,json,datetime,subprocess,os,sqlite3,csv
R=pathlib.Path.cwd(); L=R/'.test-switch-lab'; H=L/'home'; F=H/'fm'; S=H/'.omp/agent/sessions'; now=datetime.datetime.now(datetime.timezone.utc); t=lambda d:(now+datetime.timedelta(seconds=d)).isoformat()
msg=next((F/'state/t1.inbox').glob('*.msg')).read_text().split('\n--\n',1)[1].strip()
for task,prefix in [('notice-worker',''),('notice-secondmate','\u2063FROM_FIRSTMATE: delivery=123 '),('human-control','')]:
 d=S/('-orca-workspaces-'+task); d.mkdir(exist_ok=True)
 body=msg if task!='human-control' else 'Please change the implementation to option B.'
 rows=[{'type':'message','timestamp':t(-60),'message':{'role':'user','content':[{'type':'text','text':f'\u2063FIRSTMATE_OP: v1 launch-brief: # Task\nThis is a SCOUT task.\necho "{{state}}: {{note}}" >> \'{F}/state/{task}.status\'\n'}]}},{'type':'message','timestamp':t(-30),'message':{'role':'user','content':[{'type':'text','text':'[steering inbox] '+prefix+body}]}},{'type':'message','timestamp':t(-10),'message':{'role':'assistant','stopReason':'stop','content':[{'type':'toolCall','arguments':{'command':f'echo "done: report finished" >> \'{F}/state/{task}.status\''}}]}}]
 (d/'w.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in rows))
 inbox=F/'state'/f'{task}.inbox'; inbox.mkdir(exist_ok=True); (inbox/'001.msg').write_text(f'schema=fm-task-inbox.v1\nat={t(-30)}\n--\n{prefix+body}\n')
DB=L/'nm.sqlite'; c=sqlite3.connect(DB); c.executescript('create table if not exists repos(id text, upstream_url text); create table if not exists runs(id text, repo_id text, branch text, status text, pr_url text,created_at text, ci_ready_at text, parked_ms integer);');c.close()
env={**os.environ,'HOME':str(H),'FM_HOME':str(F),'CLIPROXY_KEY':''}
cmd=['python3',str(R/'bin/fm-flow-wait.py'),'--since',now.date().isoformat(),'--until',(now+datetime.timedelta(days=1)).date().isoformat(),'--as-of',t(10),'--home',str(F),'--sessions-dir',str(S),'--nm-db',str(DB),'--cache-dir',str(L/'cache'),'--out',str(L/'report'),'--release-queue',str(L/'none.jsonl'),'--no-github','--no-flash']
p=subprocess.run(cmd,env=env,text=True,capture_output=True); print(p.stdout,p.stderr); assert p.returncode==0
rows=list(csv.DictReader(open(L/'report/steers.csv'))); print(json.dumps(rows,indent=2))
for task in ['notice-worker','notice-secondmate']:
 matches=[x for x in rows if x['task']==task]; assert matches and all(x['script_template']=='model-switch-notice' for x in matches),matches
assert any(x['task']=='human-control' and not x['script_template'] for x in rows)
