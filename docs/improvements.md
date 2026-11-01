# Improvement requests

Version: 2.2
Updated: 2026-11-02

## Setup once, then send

Open **Improve this app…** from Window Factory's menu. First-run **Connection…**
uses the current Codex desktop context. Load actual projects, choose a project
and coding chat, and save the connection. Reopen Connection anytime to change it.
Older chats with no recorded server project are labelled as unfiled repository
matches: assigning one requires an explicit setup confirmation. A chat already
filed in another project is never moved silently.

Create offers a Codex project for an existing repository or a separate local
folder/Git repository. New folders are never overwritten, committed or published;
partial failures are preserved. **New chat…** requests an empty, project-bound
coding chat and starts no model work. These creation paths have fixture coverage;
desktop sidebar visibility still requires a live pilot. The project list uses
server IDs, which differ from legacy desktop-tool IDs.

After setup, describe an issue or feature and choose:

- **Save for later** stores the original request and starts no work.
- **Send to Codex** saves and sends directly to the chosen chat. The app opens
  that exact chat so its desktop owner can receive the message, then follows
  the accepted chat. There is no clipboard transfer or composer Send.

Saved requests offer **Send selected**. Accepted requests offer **Open chat**.
The chat reports questions, blockers and outcomes beside the original request.
The chosen chat's model and permissions are preserved. Changing the connection
never silently retargets an already-prepared direct request.

## Delivery, concurrency and outcomes

The shared Improvements module persists a stable message ID and write-ahead
send marker before transmission. Accepted receipts retain exact chat and turn
IDs. A receipt is delivery evidence, not implementation evidence. If a receipt
is lost, the request is unconfirmed and must be inspected before another send;
restarting or repeating a CLI command never automatically repeats that prompt.
A matching coding-chat callback can confirm arrival even if transport lost its
receipt. A second improvement cannot interrupt a running/unconfirmed improvement
in the same chat; resolve it or choose another chat first.

The actual chat must link back before product work. Outcome updates are append-only
and revision-checked. Implemented means a validated local change awaiting its
target build, not installed or owner-accepted. Separate-project outcomes are not
compared to Window Factory's running build.

**Remove from list…** hides a stale note while keeping its original request,
chat link and history for late callbacks. It neither deletes the Codex chat nor
cancels running work. Removed in-flight work still participates in concurrency
checks. Direct ID reads and callbacks remain available after removal.

## CLI and headless operation

The window and same-user CLI call the same running-app dispatcher/store owner.
Agent access must already be enabled by the owner. The Improvements window can
remain closed; the Codex desktop app must be running. Direct send opens the exact
chat, not the Improvements window, and never simulates clicks or types a prompt.
See [CLI.md](../CLI.md) for JSON operations and exact flags.

The connection CLI can list projects/chats, configure/reset setup, create provider
projects/chats, save requests, send, inspect receipts/history and remove stale
notes. Creation and sends use stable --request-id UUIDs. Local client timeouts are
45 seconds for desktop/setup calls. If a response is lost, inspect the request
or creation receipt rather than submitting a fresh operation ID blindly.

The callback command uses the installed app's absolute executable, so it works
from a separate destination without Window Factory scripts. Numeric revision is
`improvement.updates.count`.

If the tool sandbox blocks a local callback, request normal tool approval and
retry the identical operation once, preserving all IDs/payload/revision. Stop
before product work if linking review is rejected/unavailable or the approved
retry fails. Apply the same bounded retry to reads/outcomes. Never edit the live
catalog directly, change grants or claim an unconfirmed note was delivered.

## Connection boundaries and compatibility

The explicitly selected desktop context is separate from codex-ai and codex-dev.
Metadata operations use the app's bundled runtime with an independent Improvements
client identity and minimal environment; sends use the running app's actual
chat owner over its owner-only local socket. There is no executor/MCP metadata
impersonation, credential inspection/copy, account/config API, permission override,
daemon, remote control or silent CLI-identity fallback. Codex protocol changes or
an unavailable runtime/socket produce explicit errors. The connection is version
sensitive and has live proof on bundled 0.166.0-alpha.5.1.

Legacy clipboard CLI preparation remains for compatibility, but is not the normal
window flow. Old schema-1 records, UUIDs, updates and receipt reconciliation stay
readable. Background model dispatch remains retired. Saved requests are never
authorization to start work without an explicit Send.

Shared source belongs in the standalone Improvements repository. The consumer's
Modules/Improvements snapshot is generated, signed/pinned and integrity-checked.
Tests use isolated provider/socket fixtures; do not use live data or clipboard in
them. On 2026-11-02, owner setup, direct UI Send and a separately approved CLI Send
with the Improvements window closed all passed. Both returned exact receipt IDs,
linked the selected Window Factory chat and appended their exact no-code outcome
notes to their original requests. New-project/new-chat sidebar visibility still
requires a separate live pilot.
Future app-context collection must be visible, bounded and owner-controlled.
