#!/usr/bin/env python3
"""Explicit native tests; invoke on the designated remote Mac, never via discovery."""
import argparse, hashlib, json, os, plistlib, shutil, signal, subprocess, time, uuid
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--allow-native',action='store_true',required=True)
args=parser.parse_args()
project=Path(__file__).resolve().parents[2]
app=project/'build/Mochi.app'
exe=app/'Contents/MacOS/Mochi'
root=project/'build/evidence/single-instance-e2e'
root.mkdir(parents=True,exist_ok=True)
if subprocess.run(['pgrep','-u',str(os.getuid()),'-x','Mochi'],stdout=subprocess.DEVNULL).returncode==0:
    raise SystemExit('Refusing native E2E while a Mochi instance is already running on the test Mac')
run_id=uuid.uuid4().hex
scratch=root/run_id
scratch.mkdir()
owned=set(); checks=[]; contexts=[]

def run(argv,**kw): return subprocess.run([str(x) for x in argv],check=True,**kw)
def wait(fn,seconds=30):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        value=fn()
        if value: return value
        time.sleep(.05)
    raise AssertionError('Timed out waiting for '+getattr(fn,'__name__','condition'))
def check(name,value):
    checks.append({'name':name,'pass':bool(value)})
    assert value,name

def context(name):
    base=scratch/name; events=base/'events'; events.mkdir(parents=True)
    library=base/('library-'+run_id+'-'+name)
    env=os.environ.copy(); env.update(MOCHI_INSTANCE_EVENTS_DIR=str(events),MOCHI_E2E_LIBRARY_ROOT=str(library),TMPDIR=str(scratch)+'/',MOCHI_EVIDENCE_DIR=str(base))
    contexts.append((events,env))
    return events,env

def launch(bundle,env,arguments=()):
    argv=['open','-n','-F',str(bundle)]
    for key in ['MOCHI_INSTANCE_EVENTS_DIR','MOCHI_E2E_LIBRARY_ROOT','TMPDIR','MOCHI_EVIDENCE_DIR','MOCHI_INSTANCE_TEST_ID']:
        if key in env: argv+=['--env',key+'='+env[key]]
    if arguments: argv+=['--args',*arguments]
    run(argv)

def owner(events,excluded=()):
    def ready():
        for p in events.glob('*/workspace-attached.json'):
            pid=int(p.parent.name)
            if pid not in excluded: owned.add(pid); return pid
    return wait(ready)

def state(events,pid,command='snapshot'):
    p=events/f'workspace-{pid}.json'; before=time.time()
    run([scratch/'control',events,command])
    def ready():
        if p.exists():
            data=json.loads(p.read_text())
            if data['time']>=before: return data
    return wait(ready)

def quit_owner(events,pid):
    run([scratch/'control',events,'quit'])
    def gone():
        try: os.kill(pid,0); return False
        except ProcessLookupError: return True
    wait(gone)

def duplicate(events,env,binary=exe):
    before={p.name for p in events.iterdir() if p.is_dir()}
    child=subprocess.Popen([str(binary)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    check('Duplicate executable exits successfully',child.wait(timeout=10)==0)
    path=events/str(child.pid)
    check('Duplicate exits before model/library/automation startup', (path/'duplicate-exit.json').exists() and not (path/'model-created.json').exists() and not (path/'automation-configured.json').exists())
    return child.pid

report={'run_id':run_id,'started':time.time(),'binary_sha256':hashlib.sha256(exe.read_bytes()).hexdigest() if exe.exists() else None,'source_archive_sha256':hashlib.sha256((project/'source.tgz').read_bytes()).hexdigest() if (project/'source.tgz').exists() else None,'host':'mbp16','checks':checks}
try:
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    check('Metadata permits independent macOS users',not info.get('LSMultipleInstancesProhibited'))
    check('Guarded build is distinguishable from legacy releases',int(info['CFBundleVersion'])>=26 and info['MochiSingleInstanceProtocol'] is True)
    run(['xcrun','swiftc',project/'scripts/tests/fixtures/InstanceControl.swift','-o',scratch/'control'])
    legacy=scratch/'LegacyMochi.app'; (legacy/'Contents/MacOS').mkdir(parents=True)
    run(['xcrun','swiftc','-parse-as-library',project/'scripts/tests/fixtures/LegacyInstance.swift','-o',legacy/'Contents/MacOS/LegacyMochi'])
    (legacy/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleName':'Mochi','CFBundleIdentifier':info['CFBundleIdentifier'],'CFBundleExecutable':'LegacyMochi','CFBundlePackageType':'APPL','CFBundleVersion':'25','CFBundleShortVersionString':'0.2.0','LSMinimumSystemVersion':'14.0'}))
    run(['codesign','--force','--sign','-',legacy],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

    events,env=context('native-tray'); env['MOCHI_INSTANCE_TEST_ID']=run_id+'-tray'
    launch(app,env,['--single-instance-smoke-test'])
    evidence=Path(env['MOCHI_EVIDENCE_DIR'])/'tray-smoke.json'
    wait(evidence.exists,60)
    native=json.loads(evidence.read_text()); owned.add(native['pid'])
    check('All native tray/focus/idempotence checks pass',all(c['pass'] for c in native['checks']))
    report['native_tray']=native
    wait(lambda:not subprocess.run(['kill','-0',str(native['pid'])],stderr=subprocess.DEVNULL).returncode==0)

    events,env=context('concurrent'); env['MOCHI_INSTANCE_TEST_ID']=run_id+'-race'
    children=[subprocess.Popen([str(exe),'--single-instance-smoke-test'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL) for _ in range(6)]
    owned.update(p.pid for p in children)
    codes=[p.wait(timeout=60) for p in children]
    model_pids=[int(p.parent.name) for p in events.glob('*/model-created.json')]
    owner_pids=[int(p.parent.name) for p in events.glob('*/lock-acquired.json')]
    check('Six simultaneous launches elect exactly one owner',len(model_pids)==len(owner_pids)==1 and model_pids==owner_pids and codes==[0]*6)
    check('Every losing launch avoids model and automation initialization',all(not (p.parent/'model-created.json').exists() and not (p.parent/'automation-configured.json').exists() for p in events.glob('*/duplicate-exit.json')))

    events,env=context('production'); launch(app,env); pid=owner(events)
    check('Production owner obtains lock before model initialization',json.loads((events/str(pid)/'lock-acquired.json').read_text())['time']<=json.loads((events/str(pid)/'model-created.json').read_text())['time'])
    mini=state(events,pid,'minimize'); check('Workspace can be minimized',mini['miniaturized'])
    duplicate(events,env)
    restored=state(events,pid); check('Duplicate restores minimized original window',restored['visible'] and not restored['miniaturized'] and restored['active'] and restored['key'])
    hidden=state(events,pid,'hide'); check('Tray hide retains app and removes Dock presence',hidden['hidden'] and hidden['tray'] and not hidden['dock'])
    copy=scratch/'CopiedMochi.app'; shutil.copytree(app,copy)
    duplicate(events,env,copy/'Contents/MacOS/Mochi')
    restored=state(events,pid); check('Copied app restores the same tray window and Dock',restored['pid']==pid and restored['visible'] and not restored['hidden'] and restored['dock'] and restored['active'] and restored['key'])
    previous=len(list(events.glob('*/duplicate-exit.json'))); launch(copy,env)
    wait(lambda:len(list(events.glob('*/duplicate-exit.json')))>previous)
    check('Forced Launch Services duplicate avoids second model',len(list(events.glob('*/model-created.json')))==1)
    os.kill(pid,signal.SIGKILL)
    launch(app,env); new_pid=owner(events,[pid])
    check('Crash permits fresh ownership and workspace',new_pid!=pid and (events/str(new_pid)/'lock-acquired.json').exists() and state(events,new_pid)['visible'])
    quit_owner(events,new_pid)

    legacy_events=scratch/'legacy-events'; legacy_events.mkdir()
    launch(legacy,{},[str(legacy_events)])
    wait((legacy_events/'ready').exists); legacy_pid=int((legacy_events/'ready').read_text()); owned.add(legacy_pid)
    events,env=context('legacy-handoff')
    candidate=subprocess.Popen([str(exe)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    check('Live legacy owner receives handoff',candidate.wait(timeout=10)==0)
    wait((legacy_events/'reopened').exists)
    check('Legacy handoff avoids new library and automation initialization',(events/str(candidate.pid)/'legacy-handoff.json').exists() and not (events/str(candidate.pid)/'model-created.json').exists() and not (events/str(candidate.pid)/'automation-configured.json').exists())
    # Keep the old process alive while changing its on-disk bundle to guarded metadata.
    replaced=plistlib.loads((legacy/'Contents/Info.plist').read_bytes())
    replaced.update(CFBundleVersion='26',MochiSingleInstanceProtocol=True)
    (legacy/'Contents/Info.plist').write_bytes(plistlib.dumps(replaced))
    (legacy_events/'reopened').unlink()
    distribution=scratch/'DistributionMochi.app'; shutil.copytree(app,distribution)
    bin_path=Path(subprocess.check_output(['swift','build','-c','release','--show-bin-path'],cwd=project,text=True).strip())
    shutil.copy2(bin_path/'Mochi',distribution/'Contents/MacOS/Mochi')
    shutil.copy2(bin_path/'mochi-mcp',distribution/'Contents/MacOS/mochi-mcp')
    run(['codesign','--force','--sign','-',distribution/'Contents/MacOS/mochi-mcp'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    run(['codesign','--force','--sign','-',distribution],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    library=Path.home()/'Library/Application Support/Mochi/library.json'
    before_library=(library.exists(),library.stat().st_mtime_ns if library.exists() else None)
    child=subprocess.Popen([str(distribution/'Contents/MacOS/Mochi')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    owned.add(child.pid)
    check('Distribution handoff survives in-place replacement of legacy bundle',child.wait(timeout=10)==0)
    wait((legacy_events/'reopened').exists)
    check('Distribution replacement handoff leaves the real library untouched',before_library==(library.exists(),library.stat().st_mtime_ns if library.exists() else None))
    os.kill(legacy_pid,signal.SIGTERM)
    wait(lambda:subprocess.run(['kill','-0',str(legacy_pid)],stderr=subprocess.DEVNULL).returncode!=0)

    preview_events,preview_env=context('unlocked-preview'); launch(app,preview_env,['--preview']); preview_pid=owner(preview_events)
    events,env=context('preview-coexistence'); launch(app,env); pid=owner(events)
    check('Unlocked same-ID current fixture does not swallow production launch',pid!=preview_pid and (events/str(pid)/'lock-acquired.json').exists() and not (events/str(pid)/'legacy-handoff.json').exists())
    quit_owner(events,pid)
    # The unlocked preview is an artificial developer fixture, not an ownership
    # participant. Dispose of that process directly after the coexistence check.
    os.kill(preview_pid,signal.SIGTERM)
    wait(lambda:subprocess.run(['kill','-0',str(preview_pid)],stderr=subprocess.DEVNULL).returncode!=0)
    report['result']='PASS'
except Exception as exc:
    report['result']='FAIL'; report['error']=str(exc)
    raise
finally:
    cleanup_ok=True
    for pid in owned:
        command=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
        if str(project) not in command and str(scratch) not in command: continue
        try: os.kill(pid,signal.SIGTERM)
        except ProcessLookupError: continue
        end=time.monotonic()+5
        while time.monotonic()<end and subprocess.run(['kill','-0',str(pid)],stderr=subprocess.DEVNULL).returncode==0: time.sleep(.05)
        if subprocess.run(['kill','-0',str(pid)],stderr=subprocess.DEVNULL).returncode==0:
            try: os.kill(pid,signal.SIGKILL)
            except ProcessLookupError: pass
            end=time.monotonic()+5
            while time.monotonic()<end and subprocess.run(['kill','-0',str(pid)],stderr=subprocess.DEVNULL).returncode==0: time.sleep(.05)
        if subprocess.run(['kill','-0',str(pid)],stderr=subprocess.DEVNULL).returncode==0: cleanup_ok=False
    if cleanup_ok:
        retained=root/'events'/run_id
        retained.mkdir(parents=True,exist_ok=True)
        for path in scratch.rglob('*'):
            if path.is_file() and ('events' in path.parts or 'legacy-events' in path.parts or path.name in ['tray-smoke.txt','tray-smoke.json']):
                dest=retained/path.relative_to(scratch); dest.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(path,dest)
        report['evidence_directory']=str(retained)
        register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
        # Also retire fake app bundles from earlier attempts of this isolated run workspace.
        for name in ['LegacyMochi.app','CopiedMochi.app','DistributionMochi.app']:
            for bundle in root.rglob(name):
                subprocess.run([register,'-u',str(bundle)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                shutil.rmtree(bundle)
        subprocess.run([register,'-u',str(app)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for _,env in contexts:
            suite='mochi-e2e-'+Path(env['MOCHI_E2E_LIBRARY_ROOT']).name
            subprocess.run(['defaults','delete',suite],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for folder in root.rglob('library-*'):
            prior_id=folder.parent.parent.name
            if len(prior_id)==32 and all(c in '0123456789abcdef' for c in prior_id) and folder.name.startswith('library-'+prior_id+'-'):
                subprocess.run(['defaults','delete','mochi-e2e-'+folder.name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        shutil.rmtree(scratch)
        report['cleanup']={'owned_processes_exited':True,'scratch_removed':not scratch.exists(),'test_apps_unregistered':True,'private_preference_suites_deleted':True}
    else:
        report['result']='FAIL'; report['error']='Owned processes failed to exit; lock directories retained'
    report['finished']=time.time()
    (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'result':report.get('result'),'checks':len(checks),'report':str(root/'report.json')},indent=2))
    if not cleanup_ok: raise RuntimeError(report['error'])
