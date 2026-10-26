const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = fs.mkdtempSync(path.join(os.tmpdir(),'window-factory-installer-test-'));
const installer = path.resolve(__dirname,'../scripts/install.cjs');
let checks = 0;
const {runningAppPattern,validateExecutable} = require('../scripts/bundle-identity.cjs');
for (const name of ['WindowFactory','WindowFactoryNative']) {
  assert.equal(validateExecutable(name),name); checks++;
  // pgrep uses POSIX whitespace classes; normalize only that class for JS.
  const pattern = new RegExp(runningAppPattern().replace('[[:space:]]','\\s'));
  assert.equal(pattern.test(`/Applications/Window Factory.app/Contents/MacOS/${name} --background`),true); checks++;
  assert.equal(pattern.test(`/Applications/Window Factory.app/Contents/MacOS/${name}Extra`),false); checks++;
}
for (const name of ['../other','OtherApp','']) { assert.throws(()=>validateExecutable(name),/Unsupported/); checks++; }
function reject(args, expected) {
  const result = spawnSync(process.execPath,[installer,...args],{encoding:'utf8'});
  assert.notEqual(result.status,0); assert.match(result.stderr,expected); checks++;
}
try {
  reject([],/source/);
  reject(['--typo','value'],/named installer/);
  const source = path.join(root,'fake.app'); fs.mkdirSync(source);
  const target = path.join(root,'installed.app');
  fs.symlinkSync(source,target);
  reject(['--source',source,'--target',target],/symlink/);
  assert.equal(fs.readlinkSync(target),source); checks++;
  fs.unlinkSync(target);
  reject(['--source',source,'--target',target,'--previous-target',path.join(root,'missing.app')],/Rename requires/);
  fs.mkdirSync(target);
  reject(['--source',source,'--target',target,'--previous-target',source],/Rename requires/);
  fs.rmdirSync(target);
  const oldLink = path.join(root,'old-link.app'); fs.symlinkSync(source,oldLink);
  reject(['--source',source,'--target',target,'--previous-target',oldLink],/symlink previous/);
  fs.unlinkSync(oldLink);
  reject(['--source',source,'--target',target],/codesign/);
  assert.equal(fs.existsSync(target),false); checks++;
  assert.deepEqual(fs.readdirSync(root),['fake.app']); checks++;
  console.log(`native installer guards: ${checks} checks passed; rejected inputs create no install or catalog`);
} finally { fs.rmSync(root,{recursive:true,force:true}); }
