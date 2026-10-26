const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wf-signing-policy-'));
const policy = path.resolve(__dirname, '../signing-config.sh');
function probe(mode, extra = {}) {
  return spawnSync('/bin/sh', ['-c',
    'native_root="$1"; . "$2"; printf "%s" "$signing_identity"', 'probe', root, policy], {
    encoding: 'utf8', env: {PATH: process.env.PATH, WINDOW_FACTORY_SIGNING_MODE: mode, ...extra},
  });
}
try {
  assert.notEqual(probe('developer-id').status, 0);
  assert.equal(probe('adhoc').stdout, '-');
  assert.equal(probe('adhoc').status, 0);
  assert.notEqual(probe('invalid').status, 0);
  const selected = {WINDOW_FACTORY_SIGNING_IDENTITY: 'Example local selector', WINDOW_FACTORY_SIGNING_TEAM: 'ABCDEFGHIJ'};
  assert.equal(probe('developer-id', selected).status, 0);
  assert.equal(probe('developer-id', selected).stdout, selected.WINDOW_FACTORY_SIGNING_IDENTITY);
  for (const team of ['short', 'ABCDEFGHI;', 'abcdefghij']) {
    assert.notEqual(probe('developer-id', {...selected, WINDOW_FACTORY_SIGNING_TEAM: team}).status, 0);
  }
  fs.writeFileSync(path.join(root, 'signing.local.sh'), "signing_identity='Local selector'\nsigning_team=ABCDEFGHIJ\n");
  assert.equal(probe('developer-id').stdout, 'Local selector');
  assert.equal(probe('developer-id', selected).stdout, selected.WINDOW_FACTORY_SIGNING_IDENTITY);
  console.log('signing policy: fail-closed configuration, explicit development mode, valid local selection, environment override and malformed team guards passed');
} finally { fs.rmSync(root, {recursive: true}); }
