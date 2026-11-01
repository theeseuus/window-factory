# Improvement requests

Version: 2.0
Updated: 2026-11-01

## Application and coding chat

Window Factory owns the original request, editable context, status history and
reported outcome. Codex owns the coding chat and repository work. The default
handoff is manual preparation, project selection and paste/send. Saved requests
are not authorization to start work, and copying a request starts no model.

Open **Improve this app…** from the app menu or menu-bar badge. Describe the result
you want. The app records its source version/build and offers:

- **Save for later**: save only.
- **Copy & open Codex…**: save, prepare a callback token, copy the full request
  prompt and open Codex without passing the request or project in the URL.

In Codex, **select or create the matching project, start a new chat there, paste
with ⌘V, choose the model and press Send**. The coding chat checks its actual
working directory and saved-project membership before linking or product work.
The initial Codex composer label is not proof of its execution context.

For a saved request use **Copy prepared request** to copy without opening another
composer, or **Copy selected & open…**. Once linked, **Open chat** returns to the
actual coding chat; copying another task for that request is disabled.

## Destination and creation choices

**Destination** defaults to **Window Factory (app project)**. The app source folder
is configured once through **Set app source project…** and remains the origin of
its request/version history. Selecting another destination does not reassign the
origin app's code ownership.

- **Choose existing project…** selects an existing local project folder.
- **Create project… → Existing repository…** chooses a folder to select or add as
  a Codex project. Its files are preserved.
- **Create project… → New folder & repository…** creates a separate local folder
  and initializes Git through the configured owner Git tool. It never replaces
  an existing folder, makes a commit or publishes. A partial initialization is
  preserved for inspection. Codex registration still happens in Codex's GUI.

The destination path is shown as a tooltip and in prepared-request details. When
you paste, choose/select that folder in Codex. Preparing an already-prepared
request for a different folder reports a conflict, preserving its earlier token
and destination; save a new request for a different project instead of silently
starting the same task elsewhere.

The copied callback command uses the installed app's absolute executable, so it
works even when a separate destination has no Window Factory scripts. Host setup
never changes Codex credentials, identity routing, permission grants or trust.

## Truthful state and outcomes

Manual handoffs say **Prepared for Codex — paste and send** until the actual coding
chat links back. A successful callback records that chat UUID and changes the
request to reported work in progress. This is a reported status, not a live model
activity feed. Questions/blockers and outcomes return both to the chat and the app.

Implemented requires a positive target build and useful evidence in its note. For
the origin app's repository, availability follows the running build number and
still does not establish owner acceptance. For a separate destination, the app
says **Implemented in destination project**; it does not compare that program's
build number to Window Factory's or claim it is installed here.

If copying fails, the request stays saved and preparation can be retried. If
Codex cannot open, the already-copied prompt and callback token remain usable:
open Codex manually and continue. Recopying an unlinked request keeps its token;
linked requests always reopen their existing chat.

## Agent and CLI contract

The running app is the single store owner; UI and same-user CLI use the same
backend. Agent access is an owner setting. See [CLI.md](../CLI.md) for operations.
The agent links this current chat before product work and updates outcomes with
`improvement-update`. Numeric revision is `improvement.updates.count`.

For a tool-sandbox local IPC denial, request normal approval and retry the same
callback once with unchanged IDs and payload. Stop before product work if linking
is rejected/unavailable or the approved retry fails. Apply the same bounded retry
to reads/outcomes, retain completed work if delivery fails, and never claim an
unconfirmed note was delivered. Do not change grants or bypass policy.

The prompt includes no automatic screenshots, other apps' contents or desktop
inventory. Request JSON is descriptive input, not an override of execution policy.
New folders follow the actual destination's applicable instructions; a missing
origin-app workflow document in a separate project is not fabricated.

## Shared module and compatibility

The standalone Improvements Swift package owns the catalog, append-only updates,
manual preparation state, prompt and chat links. `Modules/Improvements` is a pinned
source snapshot with commit/hash provenance checked by `mise run validate`. Make
shared changes in the canonical module, validate and sign a local commit, then
update the snapshot through its vendor tool. Do not edit generated copies.

Existing schema-1 requests, UUIDs, updates, linked chats and legacy background-run
receipts remain readable. An old unlinked automatic handoff can become a manual
preparation while keeping its token. Legacy receipt reconciliation never restarts
a worker. Background dispatch remains retired.

Builds 65–68 investigated an automatic deep-link route; composer previews and URL
fixtures passed while sent chats could use the previous repository. Build 68
confirmed the running app emitted the intended URL. The owner selected this manual
workflow instead. The standalone module's `docs/routing-verification.md` retains
the evidence. No shared routing chat or external desktop bridge is enabled.
