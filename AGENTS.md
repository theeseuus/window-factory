# Working on Window Factory

Version: 1.1
Updated: 2026-11-01

- Read README.md and task-relevant docs before editing; inspect Git status.
- For improvement-request work, read docs/improvements.md and use the running
  app's CLI store API. In ordinary development sessions, check for queued requests
  when Agent access is available; report an unavailable listener without enabling
  access or treating unrelated requests as authorization for extra work.
- Keep layout/store/coordinator, app adapters, system bridge and UI responsibilities
  separate. Reviewed creation operations belong in Resources/adapters.json.
- Use `mise run validate`, `mise run test` and the relevant build checks. Swift
  and native frameworks use the installed Apple SDK; Node is mise-pinned.
- Preserve exact window/Space identity, bounded waits, cancellation, duplicate
  prevention and honest partial/failure results. Fixtures do not establish live
  macOS app/window behaviour; arrange scoped desktop pilots with the owner.
- Do not modify the installed app, live layouts/preferences, permission grants or
  external remapper/Hammerspoon ownership without the user's applicable authority.
- Keep certificate selection local/ignored; never add keys, credentials, machine
  paths, saved user catalogs or generated build output to source control.
- Keep maintained documentation version/Updated stamps current. Preserve historical
  source and observation dates separately from text revision dates.
- Follow host Git signing and human publication policy. Do not silently publish.
