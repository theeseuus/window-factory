# Architecture and evidence

Version: 1.0
Updated: 2026-10-26

Core.swift and Store.swift own recipe validation, normalized geometry, matching
and atomic catalog recovery. Operations and MacServices own bounded layout
application, cancellation and observation. Resources/adapters.json owns exact app
creation routes. The AppKit windows display and dispatch those operations.

Direct geometry/focus/stash/switcher/accordion/Space controllers remain independent
owners. TilingController owns one explicit desktop/display tree and an injected
backend; manual controls interact through float/park/reconcile events. AgentService
serializes requests and jobs, while AgentTools/AgentDirectWindows reuse the same
owners. Permissions and Agent access remain UI-owned, not CLI self-enablement.

Bridge.m isolates native and private window-server calls. Availability, target
identity, membership/frame/focus verification and bounded failure matter more than
a dispatch return code. Workspace operations must not silently switch targets,
create duplicate windows after uncertain dispatch, weaken focus checks or drive
other user windows merely to make a test pass.

The standalone split preserves the working source from window-management's native
branch. The root source history begins cleanly here; historical machine-specific
pilot records remain outside this repository. CHANGELOG records the scoped
acceptance carried forward. No Hammerspoon runtime is required by this application.

Tests cover pure geometry, matching, store recovery, controller state machines,
AppKit presentation, hotkey registry rules, socket/jobs and installer guards.
Frozen legacy fixtures preserve comparisons with the original independent Lua
implementation. Their provenance is in Tests/Fixtures/README.md.

Live acceptance before the split covered Rex/Safari/Codex layout workflows,
repeat-without-duplicates, low-window restoration, direct controls, cross-Space
selection/movement, mixed-app tiling and explicit Codex creation. These results
are scoped to their tested system/app versions; multi-display changes, unsupported
private APIs, broader adapters, login startup and more failure cases remain live
verification work. No real-desktop mutations are performed by the fixture suite.
