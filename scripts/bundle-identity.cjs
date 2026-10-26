// WindowFactory is current. The old executable is accepted only for safe
// updates/imports and running-process guards; the bundle's signing ID is stable.
const executableNames = Object.freeze(['WindowFactory','WindowFactoryNative']);
function runningAppPattern() { return `/Contents/MacOS/(${executableNames.join('|')})([[:space:]]|$)`; }
function validateExecutable(name) {
  if (!executableNames.includes(name)) throw Error('Unsupported Window Factory executable name');
  return name;
}
module.exports = {executableNames,runningAppPattern,validateExecutable};
