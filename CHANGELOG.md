# Source baseline

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
