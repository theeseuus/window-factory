const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');
for(const file of ['build.sh','install.sh','signing-config.sh','scripts/package-icon.sh','Tests/build-pilot.sh','scripts/window-factory'])execFileSync('/bin/sh',['-n',path.join(root,file)]);
for(const dir of ['scripts','Tests'])for(const name of fs.readdirSync(path.join(root,dir)))if(name.endsWith('.cjs'))execFileSync(process.execPath,['--check',path.join(root,dir,name)]);
const registry=JSON.parse(fs.readFileSync(path.join(root,'Resources/adapters.json')));assert.equal(registry.schemaVersion,1);assert.equal(new Set(registry.adapters.map(x=>x.bundleID)).size,registry.adapters.length);
for(const name of ['geometry','focus','accordion'])assert(Array.isArray(JSON.parse(fs.readFileSync(path.join(root,`Tests/Fixtures/legacy-${name}.json`)))));
assert(!fs.existsSync(path.join(root,'Hammerspoon')));console.log('Standalone source/adapter/compatibility-fixture checks passed.');
