# Source baseline

## 2026-11-01 — visible Codex handoff and linked outcomes, build 59

Adds Open in Codex and Open selected in Codex: requests open the documented
workspace/composer link, and the owner presses Send in Codex to begin. This
replaces the background runner as the normal route. The prepared prompt links
the current chat back through improvement-link before product work, then records
progress/outcomes through the existing update API. Open chat returns to that
conversation, including after completion.

Opening a composer is labelled Ready in Codex — press Send; it does not claim
work has started. Chat links and original wording survive app restarts. Failed
opens preserve requests, duplicate/conflicting links are guarded, and old run
history/receipts remain readable. The old dispatch command fails explicitly.
Space-move implementation is unchanged. See the pilot guide for the bounded
desktop integration evidence and the owner-selected extra Send step.

Source validation, the full native suite (including 34 visible-handoff and seven
historical-recovery assertions), and the signed build passed. Fixtures cover URL
encoding, draft/save behavior, linking, duplicate/conflicting callbacks, persistence
and outcome notes. Synthetic desktop project chats were created/completed/opened
without product work. These checks do not establish acceptance of a real feature
implementation or resolution of the intermittent Space-focus report.

## 2026-11-01 — explicit save or immediate agent dispatch, build 58

Replaces the ambiguous Send request action with Save for later and Send to agent
now. Saved requests can also be sent later. The owner-selected codex-ai subscription
runner starts in the configured Window Factory repository with its default model,
normal instructions, sandbox and approval review. The app tracks starting/running
state and reconciles structured results automatically, including across app restarts.

A dirty repository, active agent, failed launch or interrupted worker leaves the
request saved with an honest outcome; the backlog is never dispatched automatically.
The worker verifies a new clean signed local commit before accepting implementation.
Installation/publication remain owner actions. Request storage and the Codex adapter
are separate owners for later Claude/local backend work. Build 55's Space-move
implementation remains unchanged.

Source validation, the full native suite (37 request and 35 dispatch assertions)
and the signed build passed. Native button tests distinguish Save, Send now and
Send selected; lifecycle checks cover retries, interruption and invalid outcomes.
A real codex-ai launch returned a session ID and structured receipt using only a
generated synthetic repository, including a minimal GUI-style PATH. No saved
product request was dispatched by validation. Real feature implementation through
the new route remains for owner acceptance.

## 2026-11-01 — improvement-request pilot, build 57

Adds Improve this app in the application and menu-bar menus, with a quick request
form, reviewable view context and local history. Original wording and append-only
outcomes persist beside the layout catalog. A copy action supports an immediate
development-chat handoff; no background worker is configured. Shared CLI commands
list, read, submit and update requests with durable retry handling and revision
checks. Implemented requests await their target build until that build is running.

The pilot omits screenshots and automatic diagnostics. Existing permission and
Agent access ownership remain; request records do not need Accessibility or a
desktop mutation job. See [the pilot workflow](docs/improvements.md).

Source validation, the full native fixture suite (including 37 improvement-request
assertions), and the signed build passed. Build 57 was installed through the
verified installer; layout/previous-layout bytes and preferences were unchanged,
Accessibility and Agent access remained enabled, and the running app advertised
the three new commands and returned an empty request history. Two distinct
installer backups were retained. Real request usefulness and interaction remain
for owner use; fixture checks do not establish those outcomes.

## 2026-10-31 — quiet login/session startup, build 56

Login/service launch markers are recognised by their documented presence and
property-data forms. Restored-session open and reopen events also stay quiet;
ordinary deliberate launches/reopens still show the library. This does not change
login registration, Dock visibility, shortcuts, the agent API or build 55's
Space-move correction.

Validation, signed build and the full fixture suite passed, including real
AppleEvent-descriptor fixtures for login/service, restore yes/no and normal
launch/reopen cases. Installed background startup was verified with no visible
app windows and no foreground activation; layouts/preferences and Accessibility/
Agent access were preserved. A real reboot/login confirmation remains pending.

## 2026-10-31 — Emacs Space-move cancellation, build 55

The shared keyboard/agent move-and-follow controller now classifies input during
an attempt instead of treating every session-wide key-down counter increment as
intentional cancellation after dispatch. Matching move shortcuts do not interrupt
or queue another move. Observed other keys and pointer presses still cancel;
exact-window, desktop, membership and focus checks remain. If the scoped observer
is unavailable, the original conservative keyboard-counter guard remains.
CLI status exposes bounded event-origin metadata through diagnostic report schema
2; see [the CLI contract](CLI.md#space-move-diagnostics).

On macOS 27.2 with Emacs 32.0.50, the owner confirmed one ordinary-window keyboard
move followed and retained focus. Build 55 independently verified destination
membership/visibility and six consecutive foreground-focus samples in 516 ms.
The global key-down counter increased by one, while the available scoped observer
recorded no key-down event during the attempt. This supports delayed accounting
of the initiating shortcut, but does not identify its producer or prove that
mechanism. Earlier build-54 reports showed cancellation on a one-count increment
both before follow and during focus restoration. Four sequential CLI moves on
build 54 completed a two-desktop outward/return trip with focus and original
frame preserved, without input-counter changes.

Validation, signed build and the full fixture suite passed, including 83
Space-movement and 83 agent CLI assertions. Layouts/settings and existing
Accessibility/Agent access were preserved through installation. This is a scoped
Emacs acceptance result, not broad regression acceptance of every control or a
claim that all intermittent Space/focus issues are resolved. Hammerspoon remains
archived.

## 2026-10-26 — standalone Window Factory repository

Initial standalone source export of the accepted 0.2.0/build 48 application.
Includes layouts, direct controls, native Space operations, configurable shortcuts,
application search/launching, binary-tree tiling, same-user CLI and the sculpted
blue native icon. The bundle/data identities remain stable across the source move.

The inherited desktop pilots covered Rex/Safari/Codex and the adopted controller
commands; broader system/app scenarios remain scoped verification work. The split
keeps runtime algorithms and adapter data, freezes independent legacy test cases,
removes external Hammerspoon build dependencies and keeps machine signing selection
local. No installed app, permission grant or user catalog is migrated by this export.
