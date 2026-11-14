# In-game UI acceptance checklist

The specs in `test/` run against a fake client that draws nothing. They prove
behaviour (clicks, modes, persistence, no protected calls), not looks. This
list is what a person checks in the real WoW Forever client before a release
that touches `UI/`. Note the build, UI scale and resolution you tested with.

Setup: install the build, `/reload`, and keep chat visible (several actions
print a line there). Test once at **UI scale 100%** and once at a **reduced
scale** (Options → Graphics/Interface → UI Scale around 0.65–0.75, or
`/console uiscale 0.7`), at your usual resolution.

## Minimap button

- [ ] The gold three-ring emblem sits on the minimap edge in a round frame like other addon buttons; it is not a green square (missing `Media/Emblem.tga`).
- [ ] Hover shows a tooltip with Click / Double-click / Right-click / Drag.
- [ ] Click opens the dashboard after a short pause; click again closes it.
- [ ] Double-click opens the dashboard **on Settings** and it stays open (no flicker of open-then-close). With the dashboard open on another view, a double-click switches to Settings.
- [ ] Right-click opens the small menu under the button. Clicking an item runs it and closes the menu; clicking anywhere else or pressing Escape closes it.
- [ ] Drag moves the button smoothly around the minimap edge; releasing does not open the dashboard. `/reload`: it is where you left it.
- [ ] Menu → Hide minimap button: it disappears and chat explains `/gw minimap`. `/reload`: still hidden. `/gw minimap` brings it back.

## Dashboard

- [ ] `/gw` opens and closes it; Escape closes it; the × in the header closes it.
- [ ] Header: emblem, "Guildweaver" in gold, the version, Settings, ×. Nothing overlaps at either UI scale.
- [ ] Sidebar: Overview, Dungeons, Farming, Sync & Data, and Settings (no Guild Quests) at the bottom; the active item has a gold bar and gold text; hover highlights the others. "Collecting data" with a green light at the bottom.
- [ ] Each view: no text runs outside its card or the window, no clipped labels, no empty grey boxes.
- [ ] Drag the header: the window moves; `/reload`: same place; Settings → Reset window position centres it.
- [ ] Close on Farming, reopen: it opens on Farming. Close on Settings, reopen with a single click: it opens on the last non-settings view.
- [ ] Overview: Dungeons and Farming side by side, Sync & Data across the bottom; clicking a card opens its view; the Farming card's button starts and stops a timed run.
- [ ] Guild Quests appears nowhere (sidebar, overview, minimap menu).
- [ ] Shadow: the window looks lifted off the screen: a soft, feathered shade, a little deeper under the bottom edge, no hard rectangle, no dark band. Check it over a bright zone (snow, desert) and a dark one. If it reads as a box, set `Theme.SHADOW_SPEC` alphas to 0 and report it.
- [ ] Background: a faint stone texture in the window body and sidebar; no visible tiling seams; text stays crisp and readable.
- [ ] Dungeons: recent runs show name, date and bosses on the left, time and Cleared / Finished / Left early on the right. Objectives have a small box that turns gold when done, and an "Add an objective" field.
- [ ] Farming before any fishing: "No fishing yet this session." instead of three zeros; no `0:00` when nothing is timed.
- [ ] Farming: Start timed run → "Timing a run", the clock counts while open; Stop & save run → chat confirms. After some fishing, the fishing numbers fill in.
- [ ] Sync & Data: the waiting-update count and session start time look right. "Sync now" asks once ("Reload to sync"), the second click reloads. In combat the button is disabled. Advanced → Show reveals the diagnostic buttons; each prints to chat.
- [ ] Settings: every toggle flips and stays flipped after `/reload`.

## Dungeon HUD

Enter any 5-player dungeon.

- [ ] Compact (default): dungeon name in gold, a large grey `0:00`, "Starts on your first pull", a gold **Start** button, a row of small round boss frames with a count such as `0/4` (dark empty sockets for bosses ahead), `– + ×` at the top right. No question marks, no "PB: none yet", no `-/h`, no red Blizzard buttons.
- [ ] First pull: the timer starts (white clock) and the HUD shrinks to the minimized clock with a green light. Out of combat it returns to compact; the button now says **Pause**.
- [ ] Pause: the clock turns amber, the line says "Paused · the run stays open", the button says **Resume**. Resume continues from the same time.
- [ ] `+` → expanded: Split appears; time inside, deaths, XP, XP/hour (after five minutes), wallet change (green/red, tooltip says not profit); after a boss kill its frame gets a gold ring and the greyed face (or a skull icon after a reload); a split line; End run and Options at the bottom.
- [ ] During a boss fight (out of the combat collapse, or with collapse turned off): "Fighting <boss>" in red and a thin health bar; that boss's frame has a red ring and its face in colour. Hover frames: names for kills and the fight, "Boss ahead" for the rest.
- [ ] After five minutes in compact: `XP/hr 12,345` on the left and `Wallet/hr +4g 20s` on the right of one row, both edges aligned with the rows above, at sizes S, M, L and XL. At max level only Wallet/hr shows; with no coin moved only XP/hr shows; with neither, the row is gone.
- [ ] In combat, click `+` on the minimized HUD: it expands for this fight only; after combat it returns to your saved mode.
- [ ] `×` hides the HUD; chat explains how to bring it back. After combat it stays hidden. The run still counts (dashboard → Dungeons shows the clock running). Dashboard → Show HUD brings it back.
- [ ] Settings → Lock position: dragging does nothing. Unlock: dragging works. The HUD never jumps when changing mode (top-left corner stays put).
- [ ] Settings → Size S/M/L/XL: the HUD scales and stays near where it was; Reset HUD position puts it back at the top right.
- [ ] Settings → Show in dungeons off: the HUD disappears; dashboard → Dungeons still shows the run. On: it comes back at once.
- [ ] The HUD never covers the default target frame, action bars or raid frames in its default position at either UI scale.
- [ ] Clear the dungeon: the clock turns gold and says "Cleared · timer stopped".
- [ ] `/reload` inside the dungeon: same run, same mode, same position, same scale. `/reload` in combat: the HUD comes back collapsed and expands after combat.
- [ ] End run (click twice) closes the run; it appears under Dashboard → Dungeons → Recent runs.

## Performance spot-check

- [ ] `/gw perf` before and after a dungeon: no new collector shows large worst times; the HUD adds no visible hitching in combat.
- [ ] With the dashboard closed, nothing from Guildweaver UI runs (the HUD ticks once a second only while it is on screen).
