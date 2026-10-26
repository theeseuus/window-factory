// Local-only installation. No signing, grants, login items or global bindings.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {execFileSync} = require('node:child_process');
const {pruneBackups}=require('./backup-retention.cjs');
const {migrateData}=require('./data-migration.cjs');
const {runningAppPattern,validateExecutable} = require('./bundle-identity.cjs');
const args = process.argv.slice(2);
const allowed = new Set(['--source','--target','--data-dir','--import-catalog','--previous-target','--migrate-data-from']);
for (let i=0;i<args.length;i+=2) {
  if (!allowed.has(args[i]) || !args[i+1] || args[i+1].startsWith('--')) throw Error('Expected named installer path arguments');
}
function option(key, fallback) { const i = args.indexOf(key); if (i < 0) return fallback; if (!args[i+1] || args[i+1].startsWith('--')) throw Error(`Missing ${key}`); return path.resolve(args[i+1]); }
const source = option('--source');
const target = option('--target','/Applications/Window Factory.app');
// Product storage path; migration is explicit and refuses an existing destination.
const dataDir = option('--data-dir',path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(),'.local/share'),'window-factory'));
const catalog = option('--import-catalog');
const migrateFrom = option('--migrate-data-from');
if(migrateFrom && catalog)throw Error('Migrate data and import catalog are separate operations');
const previousTarget = option('--previous-target');
const previousInstall = previousTarget || target;
const {verifyDeveloperApp,designatedRequirement,verifyRequirement}=require('./signing-verification.cjs');
let expectedRequirement;
function verify(app){verifyDeveloperApp(app);if(expectedRequirement)verifyRequirement(app,expectedRequirement);}
function dr(app){return designatedRequirement(app);}
function run() {
  if (!source || !fs.existsSync(source)) throw Error('--source must name the signed candidate');
  if (source === target || fs.lstatSync(source).isSymbolicLink()) throw Error('Source must be a separate real app bundle');
  if (fs.existsSync(target) && fs.lstatSync(target).isSymbolicLink()) throw Error('Refusing a symlink install target');
  if (previousTarget && (previousTarget === target || fs.existsSync(target) || !fs.existsSync(previousTarget))) throw Error('Rename requires one existing old app and an unused new target');
  if (fs.existsSync(previousInstall) && fs.lstatSync(previousInstall).isSymbolicLink()) throw Error('Refusing a symlink previous install');
  verify(source); expectedRequirement=dr(source);
  if(!migrateFrom && !args.includes('--data-dir') && fs.existsSync(path.join(path.dirname(dataDir),'window-factory-native')))throw Error('Legacy data exists; use --migrate-data-from before installing');
  const executableName = validateExecutable(execFileSync('/usr/libexec/PlistBuddy',['-c','Print :CFBundleExecutable',path.join(source,'Contents/Info.plist')],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim());
  if (fs.existsSync(previousInstall)) { verify(previousInstall); if (dr(source) !== dr(previousInstall)) throw Error('Designated requirement changed; refusing update'); }
  try { execFileSync('/usr/bin/pgrep',['-f',runningAppPattern()],{stdio:'pipe'}); throw Error('Quit Window Factory before installing'); }
  catch (e) { if (e.status !== 1) throw e; }
  let catalogBytes;
  const destination = path.join(dataDir,'layouts.json');
  if (catalog) {
    execFileSync(path.join(source,'Contents/MacOS',executableName),['--validate-catalog',catalog],{stdio:'pipe'});
    catalogBytes = fs.readFileSync(catalog);
    if (fs.existsSync(destination) && !fs.readFileSync(destination).equals(catalogBytes)) throw Error('Existing catalog differs; use in-app Import to merge explicitly');
  }
  fs.mkdirSync(path.dirname(target),{recursive:true});
  const stage = fs.mkdtempSync(path.join(path.dirname(target),'.window-factory-install-'));
  const staged = path.join(stage,'Window Factory.app'), previous = path.join(stage,'previous.app');
  let replaced = false,rollbackData;
  try {
    rollbackData=migrateData(migrateFrom,dataDir,file=>execFileSync(path.join(source,'Contents/MacOS',executableName),['--validate-catalog',file],{stdio:'pipe'}));
    execFileSync('/usr/bin/ditto',[source,staged]); verify(staged);
    if (fs.existsSync(previousInstall)) {
      const backupRoot = path.join(dataDir,'install-backups'); fs.mkdirSync(backupRoot,{recursive:true,mode:0o700});
      const backup = path.join(backupRoot,`${Date.now()}-Window Factory.app`);
      execFileSync('/usr/bin/ditto',[previousInstall,backup]); verify(backup);
      fs.renameSync(previousInstall,previous);
    }
    fs.renameSync(staged,target); replaced = true; verify(target);
    if (catalogBytes && !fs.existsSync(destination)) {
      fs.mkdirSync(dataDir,{recursive:true,mode:0o700});
      fs.writeFileSync(destination,catalogBytes,{flag:'wx',mode:0o600});
      if (!fs.readFileSync(destination).equals(catalogBytes)) throw Error('Catalog copy verification failed');
    }
    fs.rmSync(stage,{recursive:true,force:true});
    console.log(`Installed ${target}\nLayouts: ${destination}\nSigned identity verified; no permission grants or shortcut changes.`);
  } catch (error) {
    if (replaced && fs.existsSync(target)) fs.renameSync(target,path.join(stage,'failed-candidate.app'));
    if (fs.existsSync(previous)) fs.renameSync(previous,previousInstall);
    if(rollbackData)rollbackData();
    throw Error(`Install failed; previous app restored where available. Evidence: ${stage}. ${error.message}`);
  }
  // Post-success housekeeping: a retention error must never roll back a verified install.
  try {
    const result=pruneBackups(path.join(dataDir,'install-backups'),{verify});
    console.log(`Backup retention: kept ${result.keep.length} distinct builds; removed ${result.remove.length} older/duplicate bundles.`);
  } catch(error) { console.warn(`Installed successfully; backup retention stopped: ${error.message}`); }
}
try { run(); } catch (e) { console.error(e.message); process.exitCode = 1; }
