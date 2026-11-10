# Sourcebook

**Where everything comes from: who drops it, where to gather it, who sells it, and what it crafts. No more alt-tabbing to a database.**

Hover any item and Sourcebook tells you the best places to get it. Type `/sb` and a leather-bound tome opens in the middle of your screen: the cover swings open, its runes glowing, and every page you visit turns like a real book while the ink writes itself in.

## The book

- **Look up any item** among more than 10,000 reagents, recipes, gear and consumables. Search as you type, filter by category, sort by name, quality, level or how many places it comes from.
- **Every source on one page**: creatures that drop it (with drop chance, level and zone), ore veins and herbs, skinning, pickpocketing, chests, containers, fishing spots and vendors (nearest first).
- **Click a source for a waypoint** to the nearest spawn: TomTom's arrow if you have TomTom, otherwise the game's own map pin.
- **Crafting**: what crafts an item, every recipe it's a reagent for, and what a recipe teaches (green when you know it).
- **Recipe plans**: reagents with how many you have in your bags and bank, and a plan for crafting it any number of times: what to craft first and what you still need to gather.

## Getting around

- Back, Index and Forward at the top of every spread, and a trail of where you've been (click any step to turn straight back to it).
- Page numbers and Previous/Next page at the foot.
- **Mouse**: right-click the book or mouse button 4 to go back, mouse button 5 to go forward, the wheel to turn pages. The red ribbon goes to the index, the gold ribbon goes back.
- **Keys**: Backspace (back), Left/Right and Page Up/Down (turn pages), Home (index), Ctrl+F (search), Escape (close). Keys the book doesn't use go straight to the game, and in combat it leaves the keyboard alone.
- The book remembers where you were, so it reopens on the same page.

## Tooltips

- **Items**: the top places to get it, the recipe that makes it, and how many recipes use it. Hold Shift for more.
- **Creatures**: the notable things they drop (recipes, reagents, rare gear).

## Learns as you play

Sourcebook remembers what you loot from what. Creatures and zones that are new in WoW Forever show up as "You looted it from", and known sources gain your own observed drop rate.

## Ways in

- `/sb` opens the book; `/sb <item name or link>` opens it on an item.
- **Ctrl+Shift-click** an item in your bags.
- **Alt-click** an item link in chat.
- A key binding: Options > Keybindings > AddOns > Sourcebook > "Look up the hovered item".

## Commands

- `/sb` or `/sourcebook`: open or close the book
- `/sb <name, link or item ID>`: look an item up
- `/sb tooltip`, `mobs`, `record`, `book` (`on`/`off`): item tooltip lines, creature drops, loot recording, the illustrated book
- `/sb classic`: a plain window instead of the book
- `/sb forget`: clear what you've looted
- `/sb help`

## Good to know

- Drop chances come from the VMaNGOS world database (vanilla 1.12 content), placed on the Forever maps. Forever's own drop rates may differ, and its new zones aren't in that data; the loot recorder fills those in as you play.
- Recipes, reagents and skill ranks come from the game's own data.
- Two folders install: **Sourcebook** (the addon) and **Sourcebook_Loot** (the data). Keep both enabled.
- The book's art uses about 160 MB of video memory while it's open.

## Source

Open source: https://github.com/PxPerfectMike/sourcebook

## License

Sourcebook is MIT licensed. The Sourcebook_Loot data is GPL-2.0, because it is derived from the VMaNGOS world database (https://github.com/vmangos/core).
