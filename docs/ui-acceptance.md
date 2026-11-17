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

## Boss tracking (Excavation Site: Wetlands, Blackfathom Deeps)

Run each once and keep the chat lines from `/gw dungeon bosses` (copy them into the PR or an issue):

- [ ] Right after entering: `/gw dungeon bosses`. Note the instance ID and difficulty, the lockout total, whether the lockout encounter list is available and what it names, and whether the Encounter Journal portrait path applies (do boss frames show real portraits before any pull?).
- [ ] After each boss: `/gw dungeon bosses` again. Note each `boss_kill id=… name via …` line. Every boss should appear once even when both ENCOUNTER_END and BOSS_KILL fire (the duplicates count goes up instead).
- [ ] Blackfathom Deeps: after Aku'mai dies the timer stops, the HUD says "Cleared · timer stopped", and diagnostics say "Final boss recognised: Aku'mai … by name only". Leaving ends the run as "Cleared (unverified)" in Recent runs. Send the Aku'mai encounter ID from the diagnostics so the registry can mark it observed (then it becomes a verified clear).
- [ ] Excavation Site: Wetlands: note which boss died last and the encounter IDs of all four (3480 Saltspine and 3481 Shadetooth are known). Until the final boss is recorded in the registry the run completes only on a full clear or `/gw dungeon finish` ("Finished by you").
- [ ] A dungeon not in the registry (e.g. The Stockade): still completes on a full clear as before.
- [ ] Hover each boss frame: kills and the current fight show the boss name; bosses ahead show a name only if the client provided one, otherwise "Boss ahead". No question marks; no Lua errors (`/console scriptErrors 1`).

## Loot alerts (needs a group and a dungeon)

The fake client cannot prove any of this: roll events, the roll frame's name and the sound ids are the real client's. Start with `/gw loot probe` and paste its lines into the PR or an issue.

- [ ] `/gw loot probe`: `GetLootRollItemInfo` and `GetLootRollItemLink` are listed as present; `START_LOOT_ROLL=yes`, `CANCEL_LOOT_ROLL=yes`, `CHAT_MSG_LOOT=yes`; roll frames `GroupLootFrame1..4` are found; `LOOT_ITEM_SELF` prints the game's "You receive loot" text. Note what is missing.
- [ ] `/gw loot`: names this character, the number of wanted items and the wishlist revision from the website. After changing the wishlist on the website and waiting a minute, `/reload`: the count and revision follow.
- [ ] `/gw loot test` and `/gw loot test boe`: a strip appears under the dungeon HUD (or near the top of the screen outside a dungeon) with an icon, the name and "Wishlist · …" in purple or "Valuable BoE · ~25g …" in gold; the HUD has a soft pulsing halo in the same colour; one chime plays. The strip goes away by itself after about nine seconds.
- [ ] `/gw loot sound soft`, `bell`, `coin`: each plays a short, pleasant sound, audible with sound effects turned low. If one is harsh or silent, note which.
- [ ] A wishlisted item comes up for a roll: the game's Need/Greed frame gets a soft purple halo around it (not a hard rectangle, nothing drawn over the icon, timer or buttons), the strip names the item, one chime. Need, Greed and Pass all still work and are exactly where they were.
- [ ] A Bind-on-Equip item worth more than the threshold comes up: gold halo and "~Ng on the AH (age)". A wishlisted BoE: purple halo, and the value is still shown.
- [ ] A Bind-on-Pickup blue that is not on the wishlist: nothing. An epic with no auction data: nothing.
- [ ] Two or three rolls at once: each frame has its own halo in its own colour; one chime for the batch; up to three rows on the strip, newest on top.
- [ ] Choose Need/Greed/Pass, or let the timer run out: that frame's halo is gone at once, the others stay. No halo is ever left on an empty spot or on a frame showing another roll.
- [ ] In combat: the alert still shows and chimes; the HUD stays in its collapsed mode; no "action blocked" or taint message (`/console taintLog 1`, then check `Logs/taint.log` for Guildweaver).
- [ ] With another loot addon that replaces the roll frames: no Lua error; the strip and the chime still work.
- [ ] Win a wishlisted item: after the "You receive loot" line, the same item does not alert again this session. After `/reload` and a sync, the website shows it as acquired.
- [ ] Settings → Loot alerts: the four controls fit along the bottom of the page without overlapping the columns above at either UI scale, and each one works (turn wishlist off: no purple alerts; change "BoE from": gold alerts follow).
- [ ] `/gw loot scan` inside a dungeon, out of combat: either "not available on this client", or it reads the bosses and reports how many. Open the Encounter Journal afterwards: your loot filter is as you left it.

## Performance spot-check

- [ ] `/gw perf` before and after a dungeon: no new collector shows large worst times; the HUD adds no visible hitching in combat.
- [ ] With the dashboard closed, nothing from Guildweaver UI runs (the HUD ticks once a second only while it is on screen).
