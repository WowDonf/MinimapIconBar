# Changelog

## v1.0.0

Initial release.

- **Collects loose minimap addon buttons** into one movable, action-bar-
  style row, gathered off the minimap edge into a single tidy bar.
- **Movable toggle button** (the "M") as the first slot: left-click to
  open/close, shift-click to lock/unlock, right-click for options, drag
  to move the whole bar. The bar is anchored by its growth corner so the
  M stays put as the row grows or shrinks.
- **De-circle + square skinning**: round minimap borders are stripped and
  each icon is squared into a stock WoW action-bar slot by default.
  **Masque** and **ElvUI** skinning are supported and selectable per
  profile.
- **Configurable layout**: button size, spacing, whole-bar scale,
  buttons-per-row, and growth direction (right/left × up/down).
- **Drag-to-reorder** when the bar is unlocked; icon order is saved per
  profile.
- **Lock in place**: shift-click the M (or the Movement option) to show
  the icons and freeze the bar in place; shift-click again to unlock and
  allow collapsing it.
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
