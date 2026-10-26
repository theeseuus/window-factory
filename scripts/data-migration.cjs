// Explicit installer-only directory move; never merge or overwrite live stores.
const fs=require('node:fs'),path=require('node:path');
function migrateData(source,destination,validate) {
  if(!source)return ()=>{};
  source=path.resolve(source);destination=path.resolve(destination);
  if(source===destination || destination.startsWith(source+path.sep) || source.startsWith(destination+path.sep))throw Error('Data migration paths must be separate');
  if(!fs.existsSync(source) || fs.lstatSync(source).isSymbolicLink() || !fs.lstatSync(source).isDirectory())throw Error('Data migration requires a real existing source directory');
  if(fs.existsSync(destination) || fs.lstatSync(path.dirname(destination)).isSymbolicLink())throw Error('Data migration destination must be unused and have a real parent');
  for(const name of ['layouts.json','layouts.previous.json']) {
    const file=path.join(source,name);
    if(fs.existsSync(file)) {
      if(fs.lstatSync(file).isSymbolicLink() || !fs.lstatSync(file).isFile())throw Error('Catalog must be a real file');
      validate(file);
    } else if(name==='layouts.json')throw Error('Migration source has no layout catalog');
  }
  fs.renameSync(source,destination);
  return ()=>{if(fs.existsSync(source))throw Error('Cannot roll back data: original location is occupied');fs.renameSync(destination,source);};
}
module.exports={migrateData};
