import os, pathlib, subprocess, tempfile, json, copy, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/Morley/.no-mistakes/evidence/01M3D6B3RZT50EQAG3RCHPJVP4')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.convergence-live-',dir=root))
base=root/'bin/.test-base-contributions.sh'
log=[]
def run(args,env):
    p=subprocess.run(args,env=env,text=True,capture_output=True,timeout=90)
    log.append({'command':' '.join(map(str,args)), 'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==0, log[-1]
    return p.stdout
def read(home,task): return json.loads((home/'data'/task/'contributions.json').read_text())
def write(home,task,data):
    p=home/'data'/task/'contributions.json';p.parent.mkdir(exist_ok=True);p.write_text(json.dumps(data,indent=2))
try:
    base.write_bytes(subprocess.check_output(['git','show','8d2ee291107d14f37ca7ef280199bebed22578c4:bin/fm-contributions.sh']))
    for label,number in [('closed',4802),('merged',5695)]:
        home=lab/label
        for part in ['data','state','config','projects']: (home/part).mkdir(parents=True)
        (home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n')
        env=os.environ.copy()
        for k in list(env):
            if k.startswith('FM_') or k.startswith('TASKS_AXI_'): env.pop(k)
        env['FM_HOME']=str(home)
        url=f'https://github.com/kunchenguid/firstmate/pull/{number}'
        write(home,'settled',{'schema':'fm-contributions.v1','task':'settled','records':[{'url':url,'kind':'pr','checked_at':None,'error':None,'pending':[],'seen':[],'notified':[],'verdict':None,'observation':None}]})
        run(['bin/fm-contributions.sh','poll'],env)
        final=read(home,'settled'); row=final['records'][0]
        assert row['observation']['state']==label and row['error'] is None, final
        (evidence/f'{label}-forge-observation.json').write_text(json.dumps(final,indent=2))
        # Reproduce an interrupted cross-owner write using the owned persisted-state contract.
        for task,error in [('diverged',None),('errored','previous forge read failed')]:
            d=copy.deepcopy(final);d['task']=task;r=d['records'][0]
            r['observation']['state']='open';r['checked_at']='2026-01-01T00:00:00Z';r['error']=error
            r['seen']=['owner-seen'];r['pending']=[{'token':'owner-pending','body':'retain this signal'}];r['notified']=['owner-pending']
            r['verdict']={'head':r['observation']['head'],'source':url,'actor':'fleet','summary':'retain owner judgment'}
            write(home,task,d)
        before={t:read(home,t) for t in ['settled','diverged','errored']}
        (evidence/f'{label}-before.json').write_text(json.dumps(before,indent=2))
        wake=home/'state/.wake-queue';wake_before=wake.read_bytes() if wake.exists() else b''
        # Real gh remains on PATH; tracing proves terminal polls never invoke it.
        run(['bash',str(base),'poll'],env)
        assert read(home,'diverged')['records'][0]['observation']['state']=='open'
        log.append({'baseline':label,'observed':'Unchanged base leaves duplicate owner open after poll'})
        for t,d in before.items():write(home,t,d)
        p=subprocess.run(['bash','-x','bin/fm-contributions.sh','poll'],env=env,text=True,capture_output=True,timeout=90)
        (evidence/f'{label}-poll-trace.txt').write_text(p.stderr)
        assert p.returncode==0 and not p.stdout,(p.returncode,p.stdout,p.stderr[-2000:])
        # Trace is execution evidence, not implementation-source matching.
        assert not any(line.lstrip('+ ').startswith('gh ') for line in p.stderr.splitlines())
        after={t:read(home,t) for t in before}
        for task in ['diverged','errored']:
            a=after[task]['records'][0];b=before[task]['records'][0]
            assert a['observation']==row['observation'] and a['checked_at']==row['checked_at'] and a['error'] is None
            for field in ['pending','seen','notified','verdict']: assert a[field]==b[field],field
        assert after['settled']==before['settled']
        assert (wake.read_bytes() if wake.exists() else b'')==wake_before
        (evidence/f'{label}-after.json').write_text(json.dumps(after,indent=2))
        input_path=home/'input.json';input_path.write_text(run(['bin/fm-fleet-snapshot.sh','--contribution-input'],env))
        snapshot=json.loads(run(['bin/fm-contributions.sh','snapshot',str(input_path),'--all'],env))
        assert snapshot['counts']['nobody']==1 and snapshot['counts']['fleet']==0 and snapshot['complete']
        (evidence/f'{label}-snapshot.json').write_text(json.dumps(snapshot,indent=2))
        stats={t:(home/'data'/t/'contributions.json').stat().st_mtime_ns for t in before}
        assert run(['bin/fm-contributions.sh','poll'],env)==''
        assert all(read(home,t)==after[t] and (home/'data'/t/'contributions.json').stat().st_mtime_ns==stats[t] for t in before)
        assert (wake.read_bytes() if wake.exists() else b'')==wake_before
        log.append({'scenario':label,'result':'Converged both divergent and errored owners; retained owner signals and verdict; no forge call or wake; snapshot reports nobody; repeat poll performed no record rewrite.'})
finally:
    (evidence/'convergence-transcript.json').write_text(json.dumps(log,indent=2))
    base.unlink(missing_ok=True)
    shutil.rmtree(lab)
print(json.dumps([x for x in log if 'scenario' in x or 'baseline' in x],indent=2))
