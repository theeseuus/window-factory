# Building and updating

Version: 1.0
Updated: 2026-10-26

Use the installed Apple Xcode SDK, Swift compiler and asset compiler. The native
`.icon` source compiles to Assets.car and a legacy ICNS fallback. mise owns the
pinned Node tool used by tests and the installer. No global package is needed.

`mise run validate` checks shell/Node syntax and standalone registry/fixture
inputs. `mise run test` runs pure/injected native tests without rearranging the
live desktop. `mise run build` compiles and signs an app bundle in the XDG cache.

For Developer ID builds, copy signing.example.sh to signing.local.sh and set your
own public certificate selector/team. This ignored file contains metadata only;
private keys remain managed by macOS. Environment variables
WINDOW_FACTORY_SIGNING_IDENTITY and WINDOW_FACTORY_SIGNING_TEAM may select the
same values. An explicit WINDOW_FACTORY_SIGNING_MODE=adhoc is available only for
local development. Missing Developer ID configuration fails closed; no silent
signing fallback occurs. A certificate-access prompt belongs to the owner.

The bundle identity remains `local.windowfactory.native`, preserving the existing
product's update continuity. The installer verifies Developer ID and requires the
new candidate's designated requirement to match the existing installation. It
never accepts a different signer simply because the certificate is valid. Backup
retention preserves two newest distinct builds; its manual apply path validates
against the installed app's designated requirement.

Before installing: finish operations, restore stashes, and turn any active tiling
session off (it is session-local). Quit Window Factory, then run:

```fish
mise run install
open '/Applications/Window Factory.app'
```

Do not install an ad hoc development build over a stable signed installation.
The installer refuses it. Neither build nor install changes Accessibility grants,
login registration, remapper bindings or unrelated app windows. After an update,
verify Accessibility, saved layouts/settings and the intended app behaviour.

Use WINDOW_FACTORY_BUILD_DIR for an alternative generated-output directory and
WINDOW_FACTORY_BUILD_NUMBER for a deliberate build-number change. Source may be
in a File Provider checkout; signed app output should stay outside that checkout.
Generated `.build` and cache output is disposable. Live catalogs, previous catalogs,
installer backups and preferences are not development cache.

Notarized distribution and an automatic updater are separate work; these scripts
provide an explicit local build/install path.
