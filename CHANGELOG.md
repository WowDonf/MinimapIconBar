# Changelog

## v1.2.0

- **Optionally collect the expansion landing-page button** (the 12.0.7
  Omnium Folio / renown button) into the bar like any other icon. Off by
  default; enable it under *Blizzard buttons* in the options. It keeps its
  native Blizzard icon and is sized, slotted, skinned, and draggable like
  the rest of the row. Turning the option back off restores it to the
  minimap after a UI reload.
- **Supports game version 12.1.0** and 12.0.7; the
  12.0.5 interface is dropped now that 12.0.7 is live.
- **No idle CPU**: the background button-scan poll now stops itself once
  the minimap settles and only re-arms on events that can add a button
  (zoning, an addon loading, a new LibDBIcon, leaving combat). A quiet
  session does no polling at all; a scan still runs the moment the button
  set actually changes. (`/mib cleanup` forces a rescan any time.)
- **Lower memory churn**: re-flowing the bar and locking buttons reuse
  shared tables and handler functions instead of allocating on every call
  and every button.

## v1.1.0

- **Supports game versions 12.0.5 and 12.0.7** from a single build (the
  TOC now declares both interface versions), so the addon loads without an
  out-of-date flag on either client.
- **Options dropdowns rebuilt on the modern menu API.** The growth,
  movement, skin, and profile dropdowns now use the current dropdown
  widget instead of the deprecated `UIDropDownMenu`, which is a known
  source of Edit Mode taint. No change to how they look or behave.

## v1.0.0

Initial release.

- **Collects loose minimap addon buttons** into one movable, action-bar-
  style row, gathered off the minimap edge into a single tidy bar.
- **Movable toggle button** (the "M") as the first slot: left-click to
  open/close, shift-click to lock/unlock, right-click for options, drag to
  move the whole bar. The bar is anchored
  by its growth corner so the M stays put as the row grows or shrinks.
- **De-circle + square skinning**: round minimap borders are stripped and
  each icon is squared into a stock WoW action-bar slot by default.
  **Masque** and **ElvUI** skinning are supported and selectable per
  profile.
- **Configurable layout**: button size, spacing, whole-bar scale,
  buttons-per-row, and growth direction (right/left × up/down).
- **Drag-to-reorder** when the bar is unlocked; icon order is saved per
  profile.
- **Lock in place**: shift-click the M (or the Movement option) to lock
  the bar; shift-click again to unlock. Locking pins the position and the
  open/closed state captured at lock time (locked open can't be closed by
  a click; locked closed can still be opened/closed). It can't be dragged
  while locked.
- **Per-character profiles** by default, plus named profiles you can
  create, copy, and share across characters.
- **Automatic button pickup**: instant for LibDBIcon buttons via a
  `LibDBIcon_IconCreated` callback, with a 5-second polling backstop for
  addons that build their button frame on toggle.
- **Combat-safe**: collection that would reparent a frame is deferred to
  `PLAYER_REGEN_ENABLED`, and the Settings panel won't open during
  combat.
- **Addon compartment entry** by the minimap clock (left-click toggles
  the bar, right-click opens options) and `/mib` slash commands for every
  setting.
