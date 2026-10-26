// Installer-backup maintenance only. Catalogs and the installed app are never targets.
const fs=require('node:fs'),path=require('node:path');
const {execFileSync}=require('node:child_process');
function metadata(app) {
 const plist=path.join(app,'Contents/Info.plist');
 const read=key=>execFileSync('/usr/libexec/PlistBuddy',['-c','Print :'+key,plist],{encoding:'utf8'}).trim();
 const bundle=read('CFBundleIdentifier'),version=read('CFBundleShortVersionString'),build=read('CFBundleVersion');
 if(bundle!=='local.windowfactory.native' || !version || !/^\d+$/.test(build))throw Error('Unrecognized backup identity: '+app);
 return {bundle,version,build};
}
function planRetention(root,readMetadata=metadata) {
 if(!fs.existsSync(root))return {keep:[],remove:[]};
 const parent=fs.lstatSync(root);if(parent.isSymbolicLink() || !parent.isDirectory())throw Error('Backup root must be a real directory');
 const entries=fs.readdirSync(root).filter(name=>!['.retention.lock','.DS_Store'].includes(name)).map(name=>{
  const match=/^(\d{13})-Window Factory\.app$/.exec(name);if(!match)throw Error('Unrecognized backup entry: '+name);
  const file=path.join(root,name),stat=fs.lstatSync(file);
  if(stat.isSymbolicLink() || !stat.isDirectory())throw Error('Backup must be a real directory: '+name);
  const info=readMetadata(file);return {name,file,...info,time:Number(match[1]),dev:stat.dev,ino:stat.ino};
 }).sort((a,b)=>b.time-a.time);
 const keep=[],remove=[],distinct=new Set();
 for(const entry of entries){const key=entry.bundle+'|'+entry.version+'|'+entry.build;
  if(!distinct.has(key) && distinct.size<2){distinct.add(key);keep.push(entry);}else remove.push(entry);
 }
 return {keep,remove};
}
function pruneBackups(root,{readMetadata=metadata,verify}={}) {
 if(!fs.existsSync(root))return {keep:[],remove:[]};
 const stat=fs.lstatSync(root);if(stat.isSymbolicLink() || !stat.isDirectory())throw Error('Backup root must be a real directory');
 const lock=path.join(root,'.retention.lock'),fd=fs.openSync(lock,'wx',0o600);
 try {
  const plan=planRetention(root,readMetadata);
  if(typeof verify!=='function')throw Error('Retained-backup verification is required');
  for(const entry of plan.keep)verify(entry.file);
  // Recheck every directory identity before deleting any; fail closed on interference.
  for(const entry of [...plan.keep,...plan.remove]){const now=fs.lstatSync(entry.file);if(now.isSymbolicLink() || !now.isDirectory() || now.dev!==entry.dev || now.ino!==entry.ino)throw Error('Backup changed during retention');}
  for(const entry of plan.remove)fs.rmSync(entry.file,{recursive:true});
  return plan;
 }finally{fs.closeSync(fd);fs.unlinkSync(lock);}
}
module.exports={metadata,planRetention,pruneBackups};
if(require.main===module){
 const args=process.argv.slice(2);
 if(args.length!==2 || !['--plan','--apply'].includes(args[0])){console.error('Use --plan or --apply with an install-backups directory');process.exit(2);}
 const root=path.resolve(args[1]);
 if(path.basename(root)!=='install-backups')throw Error('Expected exact install-backups directory');
 const {verifyDeveloperApp,designatedRequirement,verifyRequirement}=require('./signing-verification.cjs');
 const installed='/Applications/Window Factory.app';
 const verify=app=>{verifyDeveloperApp(installed);verifyRequirement(app,designatedRequirement(installed));};
 const plan=args[0]==='--apply'?pruneBackups(root,{verify}):planRetention(root);
 console.log(JSON.stringify({kept:plan.keep.map(e=>({name:e.name,version:e.version,build:e.build})),removed:plan.remove.map(e=>e.name),applied:args[0]==='--apply'},null,2));
}
