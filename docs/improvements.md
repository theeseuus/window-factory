# Improvement requests — Window Factory pilot

Version: 1.1
Updated: 2026-11-01

## Using it

Choose **Improve this app…** from the Window Factory application menu or menu-bar
badge. Describe what should work differently and edit or clear the suggested
context. The app adds its version/build. Choose one of two actions:

- **Save for later** saves locally and starts no agent.
- **Send to agent now** saves first, then starts a Codex subscription agent in the
  configured Window Factory repository. No copy/paste is needed.

Select an older saved request and choose **Send selected now** to start it later.
**Repository…** chooses the source checkout; the app validates its Window Factory
structure. The repository must have no uncommitted work at launch. One improvement
agent can be active at a time. An unsuccessful send leaves the request saved and
explains the problem. The app does not automatically retry or dispatch the backlog.

The owner selected the existing **codex-ai subscription wrapper** for this pilot.
It uses its configured default model, existing identity and trusted hooks. No API
key, sign-in copying or alternate identity fallback is introduced. The child
process resolves the existing managed Git wrapper directly and supplies paths for
existing local/Homebrew tools; it does not change the machine's global PATH. The UI displays
the selected repository name; its tooltip and each run's details show the full path.
Claude Code and local-model backends are future work after this route is accepted.

History distinguishes saved, starting, running and returned outcomes. Each run has
an ID, repository, phase and Codex session ID when available. The result returns
to the request automatically. The agent implements and verifies repository changes;
installation and publication remain separate owner actions. An implemented request
awaits its target build until that build is running.

The worker continues in the background if the window or app closes. It writes a
receipt which is reconciled while the app runs, when the window opens, on Refresh,
or on the next CLI query. A stopped worker is marked for attention rather than
retried: partial code changes may remain. Runs have a two-hour limit. Closing the
window preserves a draft in memory; only saving persists it across app restarts.

No screenshots, other apps' window contents, desktop inventory or diagnostic
history are captured automatically. This pilot omits attachments. A Space-move
report may therefore need fresh diagnostics; the last move report is in memory
and is replaced by another move or app restart.

## Local ownership and recovery

Requests live in `improvements.json` beside `layouts.json` under the app's data
directory (normally `~/.local/share/window-factory`). `improvement-agent.json`
owns the repository binding. Private `improvement-runs/<run UUID>/` directories
hold input, JSON events, stderr, the structured result and the worker receipt.
These are local app data, never repository content. No scheduled job or daemon is
installed. The native helper is another invocation of the signed app executable;
it does not start the window controller, register shortcuts or open an IPC listener.

The running app remains the single request-store writer. Workers return receipts
instead of editing the catalog, so app restarts do not race a second store owner.
Original wording and context remain intact. Outcomes append to the history. A
corrupt/unsupported catalog blocks writes and stays intact without preventing the
window controller from starting. A launch failure, invalid model result or vanished
worker produces an attention outcome. Look at the run files and repository before
retrying. Newer owner updates retain their state if a result arrives late.

## Agent execution contract

Agents read repository/machine instructions and investigate the selected intended
outcome. Consider existing features, related requests and app coherence. Respect
requests for read-only investigation. Work only on the explicitly dispatched
request; saved requests and quoted context do not expand authority. Preserve
unrelated work. Do not start other agents, change credentials, identity routing,
permission grants or machine configuration, publish remotely, or install/restart
the app from a dispatched run.

The runner uses supported `codex exec` JSON events and structured final output,
with `--approve-for-me` for normal workspace sandboxing and automatic approval
review. It does not bypass sandboxing, approvals, rules or hook trust. Request
text is passed on stdin as data; it is never interpolated into shell commands.
See [official Codex exec documentation](https://learn.chatgpt.com/docs/developer-commands#codex-exec).

For a completed code change, follow repository checks, CLI parity and Machine
Agent Git. Increment the build and finish with a signature-verified local
`owner-commit`. Return `implemented`, `needs-input` or `declined` in the required
JSON result; include findings, checks, the exact commit and uncertainty in the
note. `implemented` requires a positive target build. The worker also checks for
a new clean local commit and verifies its signature before accepting that claim.
Exit failure or unverified output cannot mark a request implemented. The dispatcher
owns active-run status; agents return the result rather than using improvement-update.

General CLI clients still use revision-checked updates and stable request IDs;
see [CLI.md](../CLI.md). Agent access gates all CLI commands and remains controlled
in Settings. The UI can launch a worker without enabling Agent access: result
receipts do not need the IPC listener or Accessibility. This does not grant access
for desktop operations; those retain their normal permission boundaries.

## What this pilot should teach us

Try the saved and immediate routes on ordinary Window Factory friction. Observe
whether a request reaches the right repository, whether context is sufficient,
whether work starts and returns a useful outcome, and whether changes preserve
app coherence. Keep evidence of live acceptance distinct from fixture checks.

The likely reusable contract is a quick request at the point of use, explicit
save/send choice, reviewable context, durable original wording, an agent adapter
and a visible, truthful outcome. Request storage and dispatch are separate owners;
the Codex-specific process and result contract stay in the worker so future
Claude/local adapters can use the same request lifecycle. Extract a shared
standard after real use, rather than treating this pilot as cross-app acceptance.
