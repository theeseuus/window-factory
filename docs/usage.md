# Usage and shortcuts

Version: 1.7
Updated: 2026-10-31

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
retained as a historically reserved chord. The Hammerspoon setup is archived
and is not an active fallback. Settings toggles act on the selected shortcut
group.

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

An application-launch shortcut opens or brings its app forward. When that app is
already frontmost, the same shortcut hides it; pressing again brings it back.
Hide completion is verified from the observed hidden state across run-loop turns,
not just the request return value. A hidden app takes the show path even if
frontmost metadata has not caught up. This hides the application, not just one
window, and does not quit it. Selecting
an app in Applications search and the CLI `app-open` command always open/activate
and never toggle hidden state.

Click Applications settings column headings to sort by name, enabled state or
whether a shortcut is assigned; click again to reverse. State groups use
alphabetical order within each group. The shortcut reference lists application
commands alphabetically. Sorting changes the view, not saved bindings.

Application selection checks Window Factory clashes and failed OS registration;
it cannot enumerate every chord owned by other remappers/apps. App opening uses
macOS Launch Services for both running and stopped apps, allowing the app to
handle activation/reopening without requesting a separate application instance.

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

## System Commands

Settings → Shortcuts → System Commands contains Emoji & Symbols, Search Files,
Keyboard Viewer and Sleep. All start unassigned. They use the existing recorder,
clash checks and group enable switch. The menu-bar and application menus also
provide these actions, and Keyboard Shortcuts shows the current assignments.

These commands use macOS directly. Emoji & Symbols opens Character Viewer.
Search Files invokes the native Option+Command+Space Finder-search shortcut after
held modifiers are released; that macOS shortcut must remain enabled. Keyboard
Viewer uses its native app where available, otherwise the Input menu through
existing Accessibility access. The current input-menu fallback requires English
menu titles and the Input menu enabled in Keyboard settings. It does not change
input sources or enable that menu automatically. Sleep sends a fixed system sleep
request; it is not display-only sleep, Lock Screen or Quit.

No launcher extension or third-party app is needed. Release an old assignment in
another shortcut owner before recording the same chord here. System actions are
not exposed through Agent access. Sleep is tested only through injected effects;
a live sleep/wake check is owner-controlled.

## Partial Space moves

Movement, following the destination and restoring focus are separately verified.
A failure can leave a window moved even when the desktop did not follow. Before
retrying, check where the window actually is. Agent access can read the latest
structured report through `status`; see [the diagnostic contract](../CLI.md#space-move-diagnostics).
The report does not change how controls behave and contains no document contents.
