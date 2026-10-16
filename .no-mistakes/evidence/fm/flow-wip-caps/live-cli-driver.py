import os, pathlib, subprocess, json
root=pathlib.Path.cwd(); base=root/'.phase-test/live'; base.mkdir(parents=True,exist_ok=True)
evidence=pathlib.Path('/Users/studio2/.no-mistakes/evidence/01M51M19ZW4JQ04JRTA7WMQ8AD/live-cli.txt')
log=[]
def home(name):
 h=base/name
 for d in ['state','data','config','user-home','projects']: (h/d).mkdir(parents=True,exist_ok=True)
 (h/'state/.last-watcher-beat').touch()
 return h
def run(h,cmd,*args,code=0):
 env=os.environ.copy(); env.update(HOME=str(h/'user-home'),FM_HOME=str(h),FM_STATE_OVERRIDE=str(h/'state'),FM_DATA_OVERRIDE=str(h/'data'),FM_CONFIG_OVERRIDE=str(h/'config'),FM_PROJECTS_OVERRIDE=str(h/'projects'),TMPDIR=str(root/'.phase-test/tmp'))
 p=subprocess.run([str(root/'bin'/cmd),*args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log.append('$ '+cmd+' '+' '.join(args)+'\n'+p.stdout+f'[exit {p.returncode}]\n')
 evidence.write_text('\n'.join(log))
 assert p.returncode==code,(cmd,p.returncode,p.stdout)
 return p.stdout
def record(h,id,fields): (h/f'state/{id}.meta').write_text(fields+'\n')
h=home('transitions'); (h/'config/wip-caps').write_text('validations=1\nmerges=1\n')
record(h,'merging','kind=ship\npr=https://github.com/example/repo/pull/1'); record(h,'validating','kind=ship'); record(h,'scouting','kind=scout\nwindow=fm-scouting')
(h/'data/scouting').mkdir(); (h/'data/scouting/brief.md').write_text('# Task\n## Captain\'s intent\nInvestigate capacity\n## Firstmate spec\nImplement the result\n')
out=run(h,'fm-pr-check.sh','validating','https://github.com/example/repo/pull/2',code=5); assert 'lane merges' in out; assert 'pr=' not in (h/'state/validating.meta').read_text(); assert not (h/'state/validating.check.sh').exists()
out=run(h,'fm-promote.sh','scouting','--mode','local-only','--yolo','off',code=5); assert 'lane validations' in out; assert 'kind=scout' in (h/'state/scouting.meta').read_text()
(h/'state/merging.meta').unlink(); run(h,'fm-pr-check.sh','validating','https://github.com/example/repo/pull/2'); assert (h/'state/validating.check.sh').exists()
run(h,'fm-pr-check.sh','validating','https://github.com/example/repo/pull/2')
out=run(h,'fm-promote.sh','scouting','--mode','local-only','--yolo','off',code=5); assert 'lane merges' in out
(h/'state/validating.meta').unlink(); run(h,'fm-promote.sh','scouting','--mode','local-only','--yolo','off'); assert 'kind=ship' in (h/'state/scouting.meta').read_text()
q=home('queue'); (q/'.tasks.toml').write_bytes((root/'.tasks.toml').read_bytes()); (q/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n'); (q/'config/wip-caps').write_text('validations=2\ninvestigations=1\nmerges=1\n')
for id,kind in [('ship-1','ship'),('ship-2','ship'),('dig-1','scout'),('dig-2','scout')]:
 subprocess.run(['tasks-axi','add',id,id,'--kind',kind,'--file',str(q/'data/backlog.md')],check=True,stdout=subprocess.DEVNULL,env={**os.environ,'HOME':str(q/'user-home')})
record(q,'live-ship','kind=ship')
out=run(q,'fm-queue-zero.sh','scan','--local'); assert 'queue ready ship-1' in out and 'queue ready dig-1' in out and 'ship-2' not in out and 'dig-2' not in out
(q/'state/live-ship.meta').unlink(); out=run(q,'fm-queue-zero.sh','scan','--local'); assert 'queue ready ship-2' in out and 'dig-2' not in out
record(q,'merging','kind=ship\npr=https://github.com/example/repo/pull/1'); out=run(q,'fm-queue-zero.sh','scan','--local'); assert 'queue ready ship-' not in out
(q/'state/merging.pr-poll-merge-notified').write_text('')
out=run(q,'fm-queue-zero.sh','scan','--local'); assert 'queue ready ship-' not in out
# Use the product marker writer to deliver a canonical merge notification, without contacting any forge.
subprocess.run(['bash','-c','. "$1/bin/fm-pr-lib.sh"; fm_pr_poll_merge_mark_notified "$2/state" merging github github.com example/repo 1','bash',str(root),str(q)],check=True)
out=run(q,'fm-queue-zero.sh','scan','--local'); assert 'queue ready ship-1' in out
run(q,'fm-pr-check.sh','merging','https://github.com/example/repo/pull/2')
out=run(q,'fm-queue-zero.sh','scan','--local'); assert 'queue ready ship-' not in out
(q/'config/wip-caps').write_text('validations=two\n'); out=run(q,'fm-queue-zero.sh','scan','--local'); assert 'queue error wip-caps' in out and 'queue ready ship-2' in out and 'queue ready dig-2' in out
log.append('All live CLI assertions passed. No forge poll executed; all task/backlog records disposable.'); evidence.write_text('\n'.join(log))
print('Live CLI scenarios passed')
