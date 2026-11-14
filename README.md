# Modern UI

World of Warcraft (WoW Forever) addon that replaces the default **action bars** and **unit frames**, with a full settings window and a setup wizard.

## Install
Copy or symlink the `modern-ui/` folder into `World of Warcraft/_forever_/Interface/AddOns/`, or run `./install.sh [AddOns path]`.

## Use
| Command | Action |
|---|---|
| `/mui` | settings window |
| `/mui wizard` | setup wizard (also runs automatically on first load) |
| `/mui unlock` / `lock` | drag frames; arrow keys nudge, right-click resets one |
| `/mui reset` | reset active profile to defaults |
| `/mui food` | print the food / water the auto macros would pick |
| `/mui kb` | hover key binding: hover a button, press a key / mouse button / wheel (Escape clears) |

There is one standard layout: action bars centered at the bottom, pet and stance bars below bar 1, xp bar on top of bar 2, the player cast bar above that, then player and target frames with the cooldown manager between them, damage meter left and minimap right of the bars (bars 3 and 4 in between, same height), tracker top right, Modern UI chat window (own tabs) bottom left edge to edge with the combat log mirrored bottom right. On narrower screens (16:9 and similar) the damage meter moves to the top left with the party frames under it, and the minimap to the top right with the tracker under it. The wizard toggles what Modern UI takes over; "Reset to defaults" restores the layout. Each new character starts on its own profile; profiles can be shared between characters.

## Design notes (built to survive patches)
- Action bars re-parent and re-skin Blizzard's own buttons, so bindings, flyouts, cooldowns and drag/drop stay Blizzard-maintained. Bar 1 does its own stance/form/vehicle paging.
- Unit frames are plain secure unit buttons. Health/power/cast code follows Midnight "secret value" rules (values go to StatusBars / `string.format` inside `pcall`, never compared).
- Minimap (re-parented out of MinimapCluster, square or round), objective tracker (anchored via Edit Mode safe *Base methods), XP / reputation bars and a conservative chat skin are included; Blizzard frames that Edit Mode manages are never touched with its overridden SetPoint.
- The micro menu and bag bar are re-parented and re-skinned the same way (own bars, fade, positions).
- Character frame, spellbook / talents, world map, game menu / popups / dropdowns, quest / gossip / merchant, loot, friends, bank, group finder / dungeon journal, achievements / collections / professions, mail / trade / auction house get a flat skin (faded Blizzard art, flat panel + border, flat item / spell icons); Blizzard keeps owning every button and panel. Spellbook and map are skinned when their load-on-demand addons load.
- UI widgets use only plain frames + textures, no Blizzard templates.
- Optional LibSharedMedia support adds fonts/textures if another addon provides it.
- TOC lists several interface versions; bump `## Interface:` when a new patch lands.

- Food & Water: keeps global macros `Food` / `Water` (`#showtooltip` + `/use item:ID`) on the best consumable in your bags, ranked by a user-ordered stat priority (attack power, spell power, ...), then buff size, restore size, item level. Stats come from the item tooltip; macros are only edited out of combat. Settings page: Food & Water.
- Data texts: one strip with gold, durability (chat warning under 20%), bag slots, frame rate / latency and a clock.
- Vendor: sells junk and repairs when a merchant opens. Fast loot takes everything at once when auto loot is on. AFK screen dims the display with a timer.
- Action bars: swing timer on Attack, shot timer and ammunition count on Auto Shot / Shoot, item / reagent counts turn red when low.
- Shaman totem bar: one secure button per element with the active totem's timer; left-click recasts the last totem of that element, right-click dismisses it.
- Temporary weapon enchants (poisons, stones, weapon buffs) with time left. Item level on equipment in bags and on the character frame, equipment set marker, new item outline, junk section value.
- Unit frames: incoming heals on the health bar, optional "only debuffs I can dispel" filter per frame.
- Profiles can be exported / imported as text (Profiles page). The import is a plain parser: no code is run, and values of the wrong type are dropped.
- Chat: web addresses are clickable and open a copy box. Loot roll frames sit on a movable anchor. BigWigs gets a "Modern UI" bar style, DBM timer bars are restyled (both untested: neither addon was installed while writing).
- Damage meter: own window drawn from Blizzard's `C_DamageMeter` data (secret-safe). Cooldown manager: Blizzard's viewers are positioned and skinned, not rebuilt.

## Target client
Built for **WoW Forever** (game type `camelot`, 12.1 engine with vanilla content, interface `16001`). Combo points show on the target frame, bar 1 pages by stance/form offset (page 6 + offset) for every class. Shamans get a Modern UI totem bar (Totems.lua).

## Status
Report Lua errors (`/console scriptErrors 1`).
