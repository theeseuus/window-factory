// Public signature checks only: never query a keychain or read key material.
const {execFileSync}=require('node:child_process');
const developerRequirement='=identifier "local.windowfactory.native" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists';
function verifyDeveloperApp(app){
 execFileSync('/usr/bin/codesign',['--verify','--strict',app],{stdio:'pipe'});
 execFileSync('/usr/bin/codesign',['--verify','-R',developerRequirement,app],{stdio:'pipe'});
}
function designatedRequirement(app){
 const text=execFileSync('/usr/bin/codesign',['-d','-r-',app],{encoding:'utf8',stdio:['ignore','pipe','pipe']});
 const line=text.split('\n').find(value=>value.startsWith('designated => '));
 if(!line)throw Error('Designated requirement unavailable');
 return '='+line.slice('designated => '.length).trim();
}
function verifyRequirement(app,requirement){verifyDeveloperApp(app);execFileSync('/usr/bin/codesign',['--verify','-R',requirement,app],{stdio:'pipe'});}
module.exports={developerRequirement,verifyDeveloperApp,designatedRequirement,verifyRequirement};
