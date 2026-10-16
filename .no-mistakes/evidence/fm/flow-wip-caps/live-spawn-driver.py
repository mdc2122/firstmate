exec((__import__('pathlib').Path('.phase-test/live.py').read_text().split("h=home('transitions')")[0]).replace("live-cli.txt","live-spawn.txt"))
h=home('spawn'); proj=h/'project'; proj.mkdir(); env=os.environ.copy(); env.update(HOME=str(h/'user-home'),TREEHOUSE_ROOT=str(h/'pool'),FM_HOME=str(h),FM_STATE_OVERRIDE=str(h/'state'),FM_DATA_OVERRIDE=str(h/'data'),FM_CONFIG_OVERRIDE=str(h/'config'),FM_PROJECTS_OVERRIDE=str(h/'projects'),FM_SPAWN_NO_GUARD='1',FM_GATE_REFUSE_BYPASS='1',TMPDIR=str(root/'.phase-test/tmp'),SHELL='/bin/bash')
for args in [['git','init','-b','main',str(proj)],['git','-C',str(proj),'-c','user.name=Test','-c','user.email=test@example.com','commit','--allow-empty','-m','fixture']]: subprocess.run(args,env=env,check=True,stdout=subprocess.DEVNULL)
sock=str(root/'.test.sock'); subprocess.run(['tmux','-S',sock,'-f','/dev/null','new-session','-d','-s','firstmate','-x','100','-y','30','-c',str(proj)],env=env,check=True)
env['TMUX']=sock+',0,0'
def spawn(id,code,scout=False):
 (h/f'data/{id}').mkdir(exist_ok=True); (h/f'data/{id}/brief.md').write_text('# Task\n## Captain\'s intent\nExercise isolated admission\n## Firstmate spec\nWait for completion\n')
 p=subprocess.run([str(root/'bin/fm-spawn.sh'),id,str(proj),*(['--scout'] if scout else ['--mode','local-only','--yolo','off']),'sleep 120'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 log.append('$ fm-spawn.sh '+id+(' <disposable-project> --scout "sleep 120"\n' if scout else ' <disposable-project> --mode local-only --yolo off "sleep 120"\n')+p.stdout+f'[exit {p.returncode}]'); evidence.write_text('\n'.join(log)); assert p.returncode==code,p.stdout
try:
 (h/'config/wip-caps').write_text('validations=1\ninvestigations=1\n'); record(h,'busy','kind=ship\nwindow=fm-busy'); spawn('blocked',5); assert not (h/'state/blocked.meta').exists()
 (h/'state/busy.meta').unlink(); spawn('admitted',0); assert (h/'state/admitted.meta').exists(); spawn('blocked-next',5)
 spawn('investigate',0,True); spawn('investigate-next',5,True)
 (h/'config/wip-caps').write_text('validations=0\n'); spawn('invalid',1)
 (h/'config/wip-caps').unlink()
 for id in ['busy-two','busy-three']: record(h,id,'kind=ship')
 spawn('default-limit',5)
 p=subprocess.run(['tmux','-S',sock,'capture-pane','-p','-t','firstmate:fm-admitted'],text=True,stdout=subprocess.PIPE); log.append('Actual tmux pane after admitted launch:\n'+p.stdout); evidence.write_text('\n'.join(log))
finally: subprocess.run(['tmux','-S',sock,'kill-server'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
print('Live real-tmux admission passed')
