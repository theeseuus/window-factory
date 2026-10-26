const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const {migrateData}=require('../scripts/data-migration.cjs');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wf-data-move-test-'));
try {
 const old=path.join(root,'old'),next=path.join(root,'new');fs.mkdirSync(old);
 fs.writeFileSync(path.join(old,'layouts.json'),'catalog');fs.writeFileSync(path.join(old,'layouts.previous.json'),'previous');
 fs.mkdirSync(path.join(old,'install-backups'));fs.writeFileSync(path.join(old,'install-backups','build'),'signed backup bytes');
 assert.throws(()=>migrateData(old,old,()=>{}),/separate/);
 fs.mkdirSync(next);assert.throws(()=>migrateData(old,next,()=>{}),/unused/);fs.rmdirSync(next);
 assert.throws(()=>migrateData(old,next,()=>{throw Error('Invalid catalog');}),/Invalid/);assert(fs.existsSync(old));assert(!fs.existsSync(next));
 const validated=[];const rollback=migrateData(old,next,p=>validated.push(path.basename(p)));
 assert.deepEqual(validated,['layouts.json','layouts.previous.json']);assert(!fs.existsSync(old));
 assert.equal(fs.readFileSync(path.join(next,'layouts.json'),'utf8'),'catalog');
 assert.equal(fs.readFileSync(path.join(next,'layouts.previous.json'),'utf8'),'previous');
 assert.equal(fs.readFileSync(path.join(next,'install-backups','build'),'utf8'),'signed backup bytes');
 rollback();assert(fs.existsSync(old));assert(!fs.existsSync(next));
 const link=path.join(root,'link');fs.symlinkSync(old,link);assert.throws(()=>migrateData(link,next,()=>{}),/real existing/);
 console.log('data migration: collision, invalid catalog, complete directory preservation, rollback and symlink guards passed');
}finally{fs.rmSync(root,{recursive:true,force:true});}
