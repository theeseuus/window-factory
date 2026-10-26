# App creation adapters

Version: 1.0
Updated: 2026-10-26

Resources/adapters.json is this repository's canonical reviewed creation registry.
It was imported byte-for-byte from the established 16-adapter baseline at the
standalone split. It no longer regenerates from another checkout. CoreTests
validates the registry and the application validates it again when loading.

Each adapter identifies an exact bundle ID/name and a kind: menu, applescript or
launch-only. Fields such as menu selector, compatibility requirement and placement
policy are explicit reviewed choices, not arbitrary recipe commands. Keep app
operations here rather than branching the shared matching/placement Coordinator.

To add or change an adapter: inspect the installed app's actual new-window route;
make the smallest registry change; run the existing core/regression checks; then
run a disposable live pilot for creation, placement, missing-window recovery and
repeat Establish without duplicates. Record the tested app/OS versions and any
Automation or minimum-size constraints. A decoded registry is not live acceptance.

Rex, Ghostty, Finder, Safari, BBEdit, Chrome, ChatGPT, Codex, Claude, Excel, Word,
PowerPoint, Keynote, Pages, Numbers and Mail are in the inherited registry. Claude
is launch-only. Some menu labels/localizations and app versions may differ;
unsupported creation should report its reason rather than retrying blindly.
Never capture private document paths, URLs or commands into public test fixtures.
