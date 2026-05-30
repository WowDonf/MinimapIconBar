# Minimap Icon Bar

Collects the loose addon buttons scattered around your minimap into one
movable, action-bar-style row — de-circled, squared off, and skinnable.

![Minimap Icon Bar](assets/Banner-1280.png)

## What it does

Most addons drop a round button onto the edge of your minimap. Get a few
addons and the minimap is ringed with them. Minimap Icon Bar gathers those
buttons off the minimap and lays them out in a single tidy bar that looks
and scales like a standard action bar.

A bag-style **toggle button** (the "M") is the first slot. Click it to
open or close the row, right-click for options, and drag it to move the
whole bar. The row grows in whichever direction you choose, and the M
stays put as it grows or shrinks.

Each button is de-circled and shown in a stock WoW action-bar slot by
default, or skinned by **Masque** or **ElvUI** if you have either
installed (selectable per profile). Newly enabled addon buttons are
picked up automatically.

## Features

- **One-click collect/expand** from a movable toggle button; the row
  hides when collapsed so the minimap stays clear.
- **Action-bar look** by default — round minimap borders are stripped and
  the icon is squared into a HUD slot. **Masque** and **ElvUI** skinning
  supported and selectable per profile.
- **Fully configurable layout**: button size, spacing, whole-bar scale,
  buttons-per-row, and growth direction (right/left × up/down).
- **Drag-to-reorder**: unlock the bar and drag icons to rearrange them;
  the order is saved per profile.
- **Lock in place**: shift-click the M (or use the Movement option) to
  lock the bar; shift-click again to unlock. Locking pins the position and
  captures the open/closed state — lock it while open and it stays open
  (a click won't close it); lock it while closed and a click can still
  open or close it. Either way it can't be dragged.
- **Per-character profiles** by default, with named profiles you can
  create, copy, and share across alts.
- **Automatic pickup** of buttons as addons are enabled — instant for
  LibDBIcon buttons, with a lightweight polling backstop for the rest.
- **Combat-safe**: collection that would reparent a frame is deferred out
  of combat, and the options panel won't open mid-combat.
- **Addon compartment entry** next to the minimap clock: left-click
  opens/closes the bar, right-click opens options.

## Install

Search "Minimap Icon Bar" on CurseForge or Wago, or copy the
`MinimapIconBar` folder from a release zip into
`World of Warcraft\_retail_\Interface\AddOns\` and `/reload`.

Click the **M** button (or type `/mib`) to get started.

## Slash commands

| Command | Effect |
| --- | --- |
| `/mib` | open the options panel |
| `/mib toggle` | open / close the bar |
| shift-click the M | lock / unlock (pins position + open state) |
| `/mib scale N` | whole-bar scale, 0.5 – 2.0 |
| `/mib size N` | button size in px |
| `/mib spacing N` | gap between buttons in px (0 = flush) |
| `/mib perrow N` | buttons per row, 1 – 12 (incl. the M icon) |
| `/mib growth DIR` | `down_right` \| `down_left` \| `up_right` \| `up_left` |
| `/mib move unlocked\|locked` | movement mode |
| `/mib skin auto\|default\|elvui\|masque` | skin profile |
| `/mib profile set\|new\|copy\|delete NAME` | manage profiles (`list` to list) |
| `/mib cleanup` | rescan for added/removed buttons |
| `/mib reset` | reset settings to defaults |
| `/mib inspect`, `dump`, `restrip` | diagnostics for button skinning |

## Compatibility

- WoW Midnight (Interface 120005, patch 12.x)
- No required dependencies. **Masque** and **ElvUI** are optional and
  used only for skinning if present.
- Collection that reparents a frame is deferred out of combat to avoid
  protected-frame taint.

## License

All Rights Reserved. See [`LICENSE`](LICENSE) for full terms — personal
in-game use of the packaged addon is permitted; copying, modifying, or
redistributing the source requires written permission.
