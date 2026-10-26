const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const {planRetention,pruneBackups}=require('../scripts/backup-retention.cjs');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wf-backup-retention-'));
let seq=1790000000000;
function add(build){const file=path.join(root,`${seq++}-Window Factory.app`);fs.mkdirSync(file);fs.writeFileSync(path.join(file,'build'),build);return file;}
const readMetadata=file=>({bundle:'local.windowfactory.native',version:'0.2.0',build:fs.readFileSync(path.join(file,'build'),'utf8')});
try{
 const old=add('20'),second=add('30'),duplicate=add('31'),latest=add('31');
 let p=planRetention(root,readMetadata);assert.deepEqual(p.keep.map(e=>e.file),[latest,second]);assert.deepEqual(new Set(p.remove.map(e=>e.file)),new Set([old,duplicate]));
 assert.throws(()=>pruneBackups(root,{readMetadata,verify:()=>{throw Error('Bad signature');}}),/Bad signature/);assert(fs.existsSync(old));assert(fs.existsSync(duplicate));assert(!fs.existsSync(path.join(root,'.retention.lock')));
 const seen=[];p=pruneBackups(root,{readMetadata,verify:f=>seen.push(f)});assert.deepEqual(seen,[latest,second]);assert.equal(fs.readdirSync(root).length,2);
 assert.equal(pruneBackups(root,{readMetadata,verify:()=>{}}).remove.length,0);
 const newer=add('32');p=pruneBackups(root,{readMetadata,verify:()=>{}});assert.deepEqual(p.keep.map(e=>e.file),[newer,latest]);assert(!fs.existsSync(second));
 fs.writeFileSync(path.join(root,'unexpected'),'leave alone');assert.throws(()=>pruneBackups(root,{readMetadata,verify:()=>{}}),/Unrecognized/);assert(fs.existsSync(newer));fs.unlinkSync(path.join(root,'unexpected'));
 fs.writeFileSync(path.join(root,'.DS_Store'),'Finder metadata');assert.equal(planRetention(root,readMetadata).keep.length,2);assert(fs.existsSync(path.join(root,'.DS_Store')));
 const link=path.join(root,`${seq++}-Window Factory.app`);fs.symlinkSync(newer,link);assert.throws(()=>pruneBackups(root,{readMetadata,verify:()=>{}}),/real directory/);assert(fs.existsSync(newer));fs.unlinkSync(link);
 fs.writeFileSync(path.join(root,'.retention.lock'),'busy');assert.throws(()=>pruneBackups(root,{readMetadata,verify:()=>{}}),/EEXIST/);fs.unlinkSync(path.join(root,'.retention.lock'));
 console.log('backup retention: distinct versions, duplicate/newest selection, verification-before-prune, idempotence, next update, unknown entry, symlink and lock guards passed');
}finally{fs.rmSync(root,{recursive:true,force:true});}
