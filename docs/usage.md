# Usage and shortcuts

Version: 1.1
Updated: 2026-10-27

The library captures app identities and normalized window geometry. It does not
capture window titles, URLs, document paths or application contents. Restore uses
existing eligible windows; Establish additionally creates supported missing slots.
Extra windows are left alone, and each result distinguishes placed/created/reused,
missing and extra windows. Several windows of one app are matched by geometry,
not by their documents or browser tabs.

Search ranks layout-name matches before app matches. Drag grips reorder layouts;
Option+Up/Down orders the selected row by keyboard. Space toggles its proportional
Quick Look preview when the list has focus. Return restores, Command+Return
establishes, Command+N captures, Command+Delete asks for deletion, Command+comma
opens Settings and Escape cancels/closes. Context menus offer row actions.

Global defaults use Hyper = Control+Option+Command. A remapper may translate held
Tab to Hyper, but Window Factory receives the ordinary modifier chord. The default
Hyper+R toggles the library; Hyper+/ toggles Keyboard Shortcuts. Hyper+Shift+R is
reserved for the separate Hammerspoon fallback. Do not register both owners for
the same command. Settings toggles act on the selected shortcut group.

| Group | Default chords |
| --- | --- |
| Geometry | Hyper+minus/equals cycles size/position; Shift reverses. Hyper+2/3/4/8 cycles halves/thirds/quarters/eighths; Shift reverses. |
| Frame | Hyper+Up centred half; Hyper+Down restore frame; Hyper+Return centre horizontally; Hyper+Shift+Return maximize; Hyper+[/] narrower/wider; Hyper+D minimize. |
| Focus | Hyper+H/J/K/L left/down/up/right. |
| Stash | Hyper+S stash/restore; restore saved stashes before quitting. |
| Switcher | Hyper+W opens/closes; arrows navigate windows/desktop groups, Return/Enter selects, Escape cancels. |
| Accordion | Hyper+Shift+S, with the anchor frontmost. |
| Spaces | Hyper+Left/Right moves and follows the focused window; native Control+Left/Right remains macOS navigation. |

Applications search, app launching, New Codex Window and Tiling controls have
configurable optional bindings. Personal assigned bindings are not universal
defaults; use the live Keyboard Shortcuts window to see the actual configuration.
F1–F20 can be recorded on their own or with Shift (for example F13 to open an
app and Shift+F13 for a separate command). Other keys require Control, Option or
Command. These use the same clash checks; an existing Raycast/system assignment
may need to be released before recording the replacement.

Application selection checks Window Factory clashes and failed OS registration;
it cannot enumerate every chord owned by other remappers/apps.

Tiling is explicitly enabled on one ordinary desktop/display. Its panel supports
split resizing, axis changes, balance/swap, float/rejoin and pause/resume. Manual
geometry floats a tile; stash parks it and restore rejoins it. Restore previous
positions uses session history. Restarting does not preserve the tree/undo session.
App constraints or changed desktop/display state can stop placement; do not treat
an unfulfilled frame request as success.

General Settings owns Agent access, Dock visibility, login startup and Accessibility
status. The app cannot grant its own permissions. Agent access is off by default
and explicitly authorizes same-user processes; it is not an agent identity system.
See [the CLI reference](../CLI.md) before using mutation commands.
