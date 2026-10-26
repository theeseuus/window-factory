// Explicit live pilot only. Normal validation never arms desktop mutations.
// Every operation goes through the installed CLI; the helper is inventory-only.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
const {execFileSync,spawnSync}=require('node:child_process');
const args=process.argv.slice(2);
const resumePath=args.length===2 && args[0]==='--resume' ? path.resolve(args[1]) : null;
if(!resumePath && (args.length!==1 || args[0]!=='--arm')) {
  console.log('Use --arm for a fresh owner-authorized disposable Rex CLI pilot, or --resume REPORT_PATH to continue a known successful Capture with its exact disposable window still present. It waits five minutes for Agent access, a different empty desktop and one newly created Rex window. After Capture, move/resize that window; after Restore, close only it. Establish recreates it once, then repeats and checks IDs. Existing Rex windows are never targets.');
  process.exit(args.length && args[0]!=='--help' ? 2 : 0);
}
const cli=path.join(os.homedir(),'.local/bin/window-factory');
const probe=path.resolve(__dirname,'../../space-helper/.build/BridgeProbe.app/Contents/MacOS/bridge-probe');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wf-rex-cli-'));fs.chmodSync(root,0o700);
const reportPath=path.join(root,'report.json'),deadline=Date.now()+300000;
const report={version:1,ok:false,startedAt:new Date().toISOString(),layoutName:'CLI Rex pilot '+crypto.randomUUID().slice(0,8),jobs:[]};
function save(){fs.writeFileSync(reportPath+'.tmp',JSON.stringify(report,null,2),{mode:0o600});fs.renameSync(reportPath+'.tmp',reportPath);}
function stage(value){report.stage=value;save();console.log(JSON.stringify({stage:value,report:reportPath}));}
function requireThat(value,message){if(!value)throw Error(message);}
function inventory(){return JSON.parse(execFileSync(probe,['rex-inventory'],{encoding:'utf8',timeout:5000}));}
const seed=resumePath ? JSON.parse(fs.readFileSync(resumePath,'utf8')) : null;
if(seed)requireThat(seed.capture?.status==='succeeded' && seed.jobs.every(j=>j.command==='capture'),'Resume requires a known successful Capture with no later operations');
const baseline=seed ? seed.rexBaseline : inventory();requireThat(baseline.ok,'Rex inventory unavailable');report.rexBaseline=baseline;
if(seed){report.resumedFrom=resumePath;report.layoutName=seed.layoutName;report.capture=seed.capture;report.target=seed.target;report.originalDisposableWindow=seed.originalDisposableWindow;report.originalLayouts=seed.originalLayouts;}
const originalIDs=new Set(Object.keys(baseline.windows));
function sameMembership(a,b){return JSON.stringify([...a].sort())===JSON.stringify([...b].sort());}
function unchanged(){const now=inventory();requireThat(now.ok && now.pid===baseline.pid,'Rex process changed');for(const id of originalIDs)requireThat(now.windows[id] && sameMembership(now.windows[id],baseline.windows[id]),'An original Rex window changed or closed; stopped');return now;}
function raw(command,extra=[]){const value=spawnSync(cli,[command,...extra],{encoding:'utf8',timeout:45000});let response;try{response=JSON.parse(value.stdout);}catch{throw Error('CLI did not return JSON');}return {exit:value.status,response};}
function call(command,extra=[]){const value=raw(command,extra);if(value.response.result?.job)report.jobs.push({command,job:value.response.result.job});if(value.exit!==0 || !value.response.ok){report.lastFailure=value;save();throw Error(command+': '+value.response.code);}return value.response;}
let instance,target,firstWindow;
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test){while(Date.now()<deadline){const result=await test();if(result)return result;await pause(500);}throw Error('Pilot timed out; no operation was retried. See its last stage and job receipts.');}
function state(){const args=instance ? ['--instance',instance] : [];return call('status',args).result.status;}
function contextArgs(){return ['--display',String(target.display),'--space',String(target.space),'--instance',instance];}
function localWindows(){const current=state();requireThat(current.desktops.some(d=>d.display===target.display && d.space===target.space),'Active desktop changed; stopped');unchanged();return call('windows',contextArgs()).result.windows;}
function closeFrame(a,b){return ['x','y','w','h'].every(key=>Math.abs(a[key]-b[key])<=2);}
function absolute(frame,screen){const w=Math.max(1,Math.min(screen.w,frame.w*screen.w)),h=Math.max(1,Math.min(screen.h,frame.h*screen.h));return {x:Math.max(screen.x,Math.min(screen.x+screen.w-w,screen.x+frame.x*screen.w)),y:Math.max(screen.y,Math.min(screen.y+screen.h-h,screen.y+frame.y*screen.h)),w,h};}
function mutate(command){const reply=call(command,['--name',report.layoutName,...contextArgs(),'--request-id',crypto.randomUUID(),'--wait-seconds','30']);const job=reply.result?.job;requireThat(job?.status==='succeeded',command+' did not fully succeed');return job;}
(async()=>{
 try {
  if(seed){
   target=seed.target;firstWindow=seed.originalDisposableWindow;
   const now=unchanged();requireThat(now.windows[String(firstWindow.id)] && sameMembership(now.windows[String(firstWindow.id)],[String(target.space)]),'Captured disposable window is no longer on its original desktop');
   requireThat(Object.keys(now.windows).filter(id=>!originalIDs.has(id)).length===1,'Unexpected extra Rex window');
   stage('resume_waiting_for_owner_on_captured_desktop');
   await until(()=>{const value=raw('status');if(value.response.code==='agent_disabled')return false;requireThat(value.response.ok,'Agent status failed');const current=value.response.result.status;instance=current.instanceID;return current.desktops.some(d=>d.display===target.display && d.space===target.space) && !current.busy;});
   const saved=call('layouts').result.layouts.find(r=>r.name===report.layoutName);requireThat(JSON.stringify(saved)===JSON.stringify(seed.capture.recipe),'Captured recipe changed');
   const local=localWindows();requireThat(local.length===1 && local[0].id===firstWindow.id,'Pilot desktop no longer contains only captured Rex');
   firstWindow=local[0];
  } else {
  stage('armed_waiting_for_agent_access_and_one_new_rex_on_another_desktop');
  let stable=0,last;
  await until(()=>{
   const status=raw('status');if(status.response.code==='agent_disabled')return false;
   requireThat(status.exit===0 && status.response.ok,'Agent status failed');
   const current=status.response.result.status;
   if(instance)requireThat(current.instanceID===instance,'Window Factory restarted; stopped');else instance=current.instanceID;
   const now=unchanged();
   for(const desktop of current.desktops){
    if(String(desktop.space)===String(baseline.focusedSpaceID))continue;
    const windows=call('windows',['--display',String(desktop.display),'--space',String(desktop.space),'--instance',instance]).result.windows;
    if(windows.length!==1 || windows[0].bundleID!=='com.superlogical.rex' || originalIDs.has(String(windows[0].id)))continue;
    const window=windows[0],extras=Object.keys(now.windows).filter(id=>!originalIDs.has(id));
    if(extras.length!==1 || extras[0]!==String(window.id) || current.busy)continue;
    const fingerprint=JSON.stringify([desktop.display,desktop.space,window.id,window.frame]);
    stable=fingerprint===last ? stable+1 : 1;last=fingerprint;
    if(stable>=3){target=desktop;firstWindow=window;return true;}
   }
   return false;
  });
  report.target=target;report.originalDisposableWindow=firstWindow;
  report.originalLayouts=call('layouts').result.layouts;
  requireThat(!report.originalLayouts.some(r=>r.name===report.layoutName),'Pilot name already exists');
  const capture=mutate('capture');requireThat(capture.recipe.windows.length===1 && capture.recipe.windows[0].bundleID==='com.superlogical.rex','Captured layout is not one Rex window');
  report.capture=capture;
  }
  const expected=absolute(report.capture.recipe.windows[0].frame,target.frame);
  stage('captured_waiting_for_owner_to_move_or_resize_disposable_window');
  await pause(5000);let changedStable=0,changedLast;
  await until(()=>{
   const windows=localWindows();requireThat(windows.length===1 && windows[0].id===firstWindow.id,'Disposable window changed before Restore');
   if(state().busy)return false;
   const frame=windows[0].frame,delta=['x','y','w','h'].reduce((sum,key)=>sum+Math.abs(frame[key]-firstWindow.frame[key]),0);
   if(delta<40)return false;
   const stamp=JSON.stringify(frame);changedStable=stamp===changedLast ? changedStable+1 : 1;changedLast=stamp;return changedStable>=3;
  });
  stage('restoring');report.restore=mutate('restore');
  const restored=localWindows();requireThat(restored.length===1 && restored[0].id===firstWindow.id && closeFrame(restored[0].frame,expected),'Restore frame/window mismatch');
  stage('restored_waiting_for_owner_to_close_only_disposable_window');
  await until(()=>{
   const windows=localWindows(),now=unchanged();
   if(now.windows[String(firstWindow.id)])return false;
   requireThat(windows.length===0,'A different window appeared on the pilot desktop');
   requireThat(Object.keys(now.windows).every(id=>originalIDs.has(id)),'An unexpected new Rex window exists');return !state().busy;
  });
  stage('establishing_missing_rex');report.establish=mutate('establish');
  const created=localWindows();requireThat(created.length===1 && created[0].bundleID==='com.superlogical.rex' && !originalIDs.has(String(created[0].id)),'Establish did not create exactly one disposable Rex window');
  requireThat(report.establish.receipt.created===1 && report.establish.receipt.missing===0,'Missing-window receipt mismatch');
  report.recreatedWindow=created[0];
  stage('repeating_establish');report.repeat=mutate('establish');
  const repeated=localWindows();
  requireThat(repeated.length===1 && repeated[0].id===created[0].id && closeFrame(repeated[0].frame,expected),'Repeat duplicated/replaced/misplaced the test window');
  requireThat(report.repeat.receipt.created===0 && report.repeat.receipt.reused===1 && report.repeat.receipt.missing===0,'Repeat receipt reports an unexpected creation');
  const finalInventory=unchanged(),extra=Object.keys(finalInventory.windows).filter(id=>!originalIDs.has(id));
  requireThat(extra.length===1 && extra[0]===String(created[0].id),'Final Rex inventory contains unexpected windows');
  const finalLayouts=call('layouts').result.layouts;
  for(const recipe of report.originalLayouts)requireThat(JSON.stringify(finalLayouts.find(r=>r.name===recipe.name))===JSON.stringify(recipe),'An original layout changed');
  report.otherRexWindowsUnchanged=true;report.otherLayoutsUnchanged=true;report.ok=true;report.finishedAt=new Date().toISOString();stage('complete_test_window_and_pilot_layout_left_for_owner');
 }catch(error){report.error=String(error.message || error);report.finishedAt=new Date().toISOString();stage('stopped');process.exitCode=1;}
})();
