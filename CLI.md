# Window Factory CLI

Version: 1.4
Updated: 2026-11-01

`scripts/window-factory` (or the installed binary with `--cli`) provides JSON access to the running app's layout, application, tiling and direct window operations.
It does not open Window Factory’s library, confirmation panels or Settings,
activate Window Factory, register shortcuts, start a second window-controller instance or grant
permissions. Establish can open the requested target-app windows; macOS may still
request an adapter’s Automation permission if it has not already been granted.
Window operations still need
a logged-in macOS desktop session and the installed app's Accessibility access.

## Enable or disable

Use **Settings → General → Agent access**. It defaults off. The CLI cannot turn
itself on. Off removes the listener, rejects new requests and cancels the active
CLI-owned job at the next cancellation check. Completed changes remain; disabling
access is not an undo. Normal hotkeys are independent; Hammerspoon is archived.
The preference persists across app restarts; quitting stops the listener.

The endpoint permits processes running as the current macOS user. It does not
identify a particular agent or distinguish agents from other same-user programs.
It is a Unix socket in `~/.cache/window-factory/agent/control.sock`, protected by
a private 0700 directory, 0600 socket, same-user peer checks and an exclusive
listener lock. There is no TCP listener. Requests/responses have a one-megabyte
limit, short transport timeouts and at most eight connected clients.

## Commands

| Command | Result |
| --- | --- |
| `status` | App instance ID, access state, Accessibility state, busy flag, active ordinary desktop/display IDs and visible frames |
| `capabilities` | Supported command names and current status |
| `layouts` | Saved recipes from the app's in-memory catalog |
| `windows --display ID --space ID` | Eligible windows on that active desktop: IDs, process IDs, app identities and frames |
| `capture --name NAME --display ID --space ID` | Capture and save through the existing capture service/store; replacement requires `--replace` |
| `restore --name NAME --display ID --space ID` | Reuse the existing Coordinator to place matching windows |
| `establish --name NAME --display ID --space ID` | Reuse the same Coordinator and full app adapter registry to create missing windows and place the layout |
| `job --job UUID` | Job state, progress, result or error |
| `cancel --job UUID` | Request cancellation of that CLI job only |

The IDs are the native display/Space IDs returned by `status`, not the desktop
ordinal printed in the menu bar. Desktop-modifying requests require both IDs. Improvement record operations
are local data operations and take neither ID. A changed
or unavailable desktop produces `context_changed` and does not start an operation.
The existing engine continues checking its context during execution.

## Extended controls (build 46)

The command set now includes the following operations. Mutations use the same
tracked jobs, request-ID deduplication, access gate and busy protection as layouts.
They require explicit active display/Space IDs, including catalog mutations.

| Command | Target and result |
| --- | --- |
| `apps` | Installed app identities and running state; credential apps, Hammerspoon and Window Factory itself excluded |
| `app-open --bundle-id ID` | Activate/open an exact installed app through ApplicationLauncher; activation can follow its existing window to another Space |
| `new-window --bundle-id ID` | One reviewed adapter creation on the requested current desktop; app must already be running |
| `tiling-status` | Session target/state, selected/tiled/floating/parked IDs, split UUIDs/ratios, options, exclusions and undo availability |
| `tiling --action ACTION` | Enable/disable, pause/resume, select, float/rejoin, split edit, balance/swap, restore previous positions and gap/margin/axis options |
| `window --action ACTION --window ID` | Exact-window geometry, focus, stash/restore, adjacent-Space move-and-follow and accordion |
| `layout-rename --name NAME --new-name NAME` | Rename through the atomic store and retain library ordering |
| `layout-delete --name NAME --confirm` | Explicit deletion with previous-catalog recovery |
| `layout-order --names-json JSON` | Every current layout name exactly once |
| `layout-export` | Catalog in `result.tools.catalog`, order in `result.tools.names` |
| `layout-import --input FILE` | Client reads a raw Catalog JSON file and sends it inline; merge rejects conflicting replacements |

`--help` lists action flags. Window geometry names are `sizeNext`, `sizePrevious`,
`positionNext`, `positionPrevious`, `halvesNext`, `halvesPrevious`, `thirdsNext`,
`thirdsPrevious`, `quartersNext`, `quartersPrevious`, `eighthsNext`,
`eighthsPrevious`, `centeredHalf`, `restoreFrame`, `centerHorizontally`, `narrower`,
`wider`, `maximize`, `minimize`. Manual geometry floats a tiled window as usual.
Stash is explicit/idempotent rather than a toggle; `status.stashedWindowIDs`
identifies saved stashes for `restore-stash` even if offscreen.

Tiling actions `select`, `float`, `rejoin`, `swap` require `--window ID`.
`split` requires `--split UUID` plus `--ratio 0.15...0.85` and/or
`--axis columns|rows`. `options` requires at least one of `--gap 0...48`,
`--margin 0...48`, `--axis columns|rows`. Other actions take no window ID.
`move-space` requires `--direction -1` or `1`. Tiling operations have a bounded
settlement wait and pause on cancellation/timeout. The session must belong to
the requested desktop. Status reports cached `observedFrame` alongside
`plannedFrame`; use `windows` for a fresh live inventory. New-window completion
confirms creation, not completion of the subsequently scheduled tiling reflow.

New tool jobs place their result in `result.job.tools`; read-only tool queries use
`result.tools`. The original layout recipe/receipt fields remain unchanged.
Import accepts Catalog JSON, not the full export response envelope. It never asks
the app to read an arbitrary filesystem path. Export does not write files.

Preferences, shortcut editing, permission grants, arbitrary scripts, interactive
switcher driving and application-state capture remain outside the agent API.
Tiling exclusions are inspectable; edit them through Settings. Use explicit focus
rather than simulating the switcher. Existing working keyboard paths are shared,
not duplicated. Broader live mutation acceptance remains a separate desktop pilot;
fixture checks are not proof of all installed app/Space scenarios.

## Practical use

Run the installed app normally and enable Agent access. From this checkout, use
`./scripts/window-factory status`; the examples below use `window-factory` as the
launcher name if you have added it to your PATH:

```fish
window-factory --help
window-factory status
window-factory capabilities
window-factory layouts
```

Choose the intended display/Space IDs from status. These numbers are examples;
replace them with the actual current IDs before running a layout operation:

```fish
set wf_display 1
set wf_space 42
window-factory windows --display $wf_display --space $wf_space
window-factory capture --name 'Agent layout' --display $wf_display --space $wf_space --wait
window-factory restore --name 'Agent layout' --display $wf_display --space $wf_space --wait
window-factory establish --name 'Agent layout' --display $wf_display --space $wf_space --wait
```

Without `--wait`, mutations return an accepted/running job immediately. `--wait`
polls for up to 60 seconds; `--wait-seconds N` accepts 1–300 seconds instead.
Waiting expiry or a broken connection does not undo or automatically retry a
mutation. The last known job is included when polling is interrupted. Inspect it:

```fish
set wf_job 'returned-job-uuid'
window-factory job --job $wf_job
window-factory cancel --job $wf_job --wait
```

A `busy` response rejects a mutation rather than queuing it. The app's frozen
capture, layout task, modal dialog, direct-controller tasks and open switcher
block a new CLI mutation. CLI layout jobs occupy the existing library task slot,
so the working controls retain their normal workspace-busy protection.

## Results, retrying and recovery

Responses use `version`, `requestID`, `instanceID`, `ok`, `code`, `result` and
`error`. Dates are ISO 8601. `ok` describes the request/query, not an unfinished
operation. Inspect `result.job.status`: `running`, `succeeded`, `partial`,
`failed` or `cancelled`. Layout receipts retain the existing `placed`, `created`,
`reused`, `missing`, `extras` and `failures` fields. A cancellation/error can have
completed side effects; `sideEffectsPossible` is deliberately conservative.

The CLI exits 0 for a successful query/accepted request or a completed successful
job, 1 for a rejected request or a partial/failed/cancelled/wait-expired job, and
2 for local argument/transport failures. Command results are one JSON object on
stdout. Help is plain text. No raw requests or window inventories are logged.

Each invocation creates a request UUID. `--request-id UUID` makes it explicit:
identical modifying requests return the same job in the same app session;
changed arguments with that ID are rejected. The last 100 jobs are retained in
memory. Older executed request IDs remain tombstoned, so they return
`result_expired` rather than running twice. After 4096 modifying requests the
session refuses new ones until restart. No job history is persisted to disk.

Use `--instance UUID` from status to bind a request to the observed app session.
An app restart changes the instance ID and loses in-memory jobs/deduplication.
Never blindly resubmit after an uncertain outcome or app restart: inspect current
windows/layouts and reconcile first. No command silently retries application
window creation; the accepted Coordinator's existing rules apply.

## Ownership and testing

The app bundle contains the CLI entry point (`WindowFactory --cli ...`). The
repository launcher `scripts/window-factory` calls that installed entry point;
a personal PATH wrapper is optional. The app owns permissions, the access
preference, catalog, socket and ephemeral jobs.

The agent test suite uses the real socket transport and an injected operation
backend in temporary private directories. It covers permissions, duplicate
listeners, disabled access, argument/context/instance validation, request IDs,
busy rejection, structured receipts/partial results, capture replacement,
cancellation and disabling access mid-job. It does not move desktop windows or
claim live app creation compatibility. Installed-app read-only and layout pilots
are scoped separately in [architecture and evidence](docs/architecture.md).

## Space-move diagnostics

After a move-and-follow attempt, `status` and `capabilities` include an optional
`result.status.lastSpaceMove` report. It is absent before the first attempt and
resets when the app restarts. It describes the latest shortcut or agent attempt;
a later move replaces it. Rejected busy CLI jobs do not replace the active report.

The report identifies the app by bundle ID/version and the exact window/process,
display and Space IDs. It includes phase timings, move/follow dispatch results,
last observed membership/visibility, focus-request statuses and observations,
input-counter deltas (key down, left/right/other mouse down), ignored repeat-move
requests and the final outcome/detail. `failedCheck` categorizes input,
eligibility, topology or pre-move focus guards where available. A phase tells
where the operation stopped, not the underlying app-specific cause.

Report schema 2 also includes `inputObserverAvailable`, up to eight `inputEvents`
with elapsed milliseconds, source PID, Quartz source-state ID, move-shortcut
classification and autorepeat, plus `unattributedKeyboardDelta`. PID zero or a
source-state value alone does not identify physical hardware or prove which
remapper generated an event. Resolve a live nonzero PID separately if needed.
No key codes, typed characters or modifier values are retained.

A listen-only event tap exists only during each move, then is removed. It neither
consumes nor synthesizes input. Pointer presses and observed non-move keys still
cancel. Configured move shortcuts (including repeats) do not cancel the active
move; they do not queue another move. Before dispatch, an unexplained key-count
change still cancels. After dispatch, a counter-only keyboard change does not
strand the window: follow and focus can finish while all existing exact-window,
eligibility, topology, membership, desktop-context and pointer guards remain.
If the event observer is unavailable or disabled, the original conservative
keyboard-counter check remains in effect; no permission is requested by the CLI.
The same policy applies to keyboard and agent requests.

There is no disk history, background polling, window title or document path in
the report. Inspect it before another move; do not blindly retry a failed move
because its first stage may already have completed.


## Improvement requests

These commands share the UI's durable request store and dispatcher, use normal
Agent access, and do not require Accessibility, desktop context, an idle
window-operation job or `--wait`. They return immediately in `result.tools`.
Only `improvement-dispatch` launches an agent. All are advertised by `capabilities`.

| Command | Result |
| --- | --- |
| `improvement-agent [--repository PATH]` | `improvementAgent`: selected repository and fixed `codex-ai` runner. Supplying an absolute path validates and saves the app-owned repository binding. |
| `improvement-dispatch --improvement UUID` | Saves a run for that existing request and starts a background agent in its configured repository; returns the updated `improvement`. |
| `improvements [--offset N]` | `improvements`: up to 100 summaries, oldest first; `improvementCount`: total. Continue with offsets 100, 200, etc. Each summary includes ID, excerpt, state, revision and running-build status. |
| `improvements --improvement UUID` | `improvement`: full original text, context, source version/build, creation date and append-only updates |
| `improvement-submit --text TEXT [--context TEXT]` | Saves a queued request; its stable ID is the invocation's `--request-id` (generated if omitted) |
| `improvement-update --improvement UUID --revision N --state STATE --note TEXT [--target-build N]` | Appends an outcome to the named request using optimistic revision checking |

States: `queued`, `working`, `needs-input`, `implemented`, `declined`.
`implemented` requires a positive `--target-build`; other states omit it.
Text and outcome notes must be nonblank and at most 8,000 UTF-8 bytes; context is
at most 1,000 bytes. Context is caller-supplied for CLI submissions; the app adds
its own version/build. Outcomes should include validation and relevant commit.
No automatic desktop inspection or screenshot capture occurs.

Submit retries with the same request ID return the existing record only when text,
context and source agree, including across restarts. Outcome retries reuse the
same operation `--request-id`, revision, state, note and target build. A different
payload returns `request_conflict`; a fresh update using an outdated revision
returns `revision_conflict`. Unknown IDs return `improvement_not_found`.
Invalid content returns `invalid_improvement`; unexpected fields are rejected.
An unsupported schema returns `improvements_unreadable`; malformed or inaccessible
storage returns `operation_failed`. Failed reads never reset or overwrite history.

Availability is derived from the running app build and the latest implemented
update's target build. A local commit alone does not establish availability.
See [the pilot workflow](docs/improvements.md) for handling requests and evaluating
whether the pattern should become a reusable standard.


Dispatch is explicit; submission alone remains saved for later. Its run ID is the
invocation's request ID. Reusing the same `--request-id` for the same request
returns the recorded run outcome without relaunching, including after failure;
an intentional retry uses a fresh request ID. Reuse for another request is rejected.
 Each full request
may now include `runs`, an optional backwards-compatible array recording ID,
repository, start/finish times, source revision, phase and session ID. Existing
records without `runs` remain readable. `queued` is displayed as Saved for later;
active runs distinguish Starting agent from Agent running. Phase/result receipts
are reconciled on queries and by the running app. No command waits for model work.

Dispatch errors include `repository_required`, `invalid_repository`,
`repository_dirty`, `repository_check_failed`, `unsupported_runner`, `agent_busy`,
`request_finished` and `agent_launch_failed`. A failed dispatch never discards a
saved request. No automatic retry occurs. The worker uses the selected repository,
existing subscription wrapper, configured default model and normal policy; it
returns its result through private files even if the UI app exits. See the pilot
workflow for execution, timeout, failure and installation boundaries.
