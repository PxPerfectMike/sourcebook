# Sourcebook

A World of Warcraft: Forever addon that answers "where do I get this?" without alt-tabbing to a
database site: who drops an item and how often, which veins and herbs give it, who sells it, what
it's crafted from, and what it's a reagent for.

## What it does

- **The book**: `/sb` opens a leather-bound tome in the middle of the screen. The cover swings
  open in perspective, its runes glowing, light spilling out of the pages; every view is a spread
  of parchment, and moving between views turns a real rendered page (with its shadow and a trail
  of sparks) while the ink fades away and writes itself back in. The index has a search, category
  filters and four sort orders; an item's entry lists every source (click one for a waypoint) and
  what it crafts; a recipe shows what you have and a plan for crafting it N times.
- **Getting around the book**: every spread has Back and Index on the left page, the trail of
  where you've been (click any step to turn straight back to it) and Forward on the right, and
  page numbers with Previous/Next page at the foot. History lasts the whole session, so the book
  reopens where you left it.

  | Do | Mouse | Keys |
  |---|---|---|
  | Back | right-click anywhere on the book, mouse button 4, gold ribbon | Backspace, Left (on a single page) |
  | Forward | mouse button 5 | Right (on a single page) |
  | Previous / next page | mouse wheel, page links | Left / Right, Page Up / Page Down |
  | Index | red ribbon, Index link | Home |
  | Search | the search line | Ctrl+F; Enter opens the best match; Escape clears, then lets go |
  | Close | top-right gold corner, click outside | Escape |

  Keys the book doesn't use go straight to the game, and in combat it doesn't touch the keyboard.
  `/sb classic` opens the plain window instead, and `/sb book off` makes that the default.

- **Item tooltips**: the best places to get an item (drops with chance and level, ore veins and
  herbs, skinning, pickpocketing, chests, containers, fishing, vendors), the recipe that crafts it,
  the recipes it's a reagent for, and what a recipe item teaches (green if you know it). Hold
  Shift for more lines.
- **Creature tooltips**: the notable things a creature drops (recipes, reagents, rare gear).
- **Ways in**: `/sb <name>`, Ctrl+Shift-click an item in your bags, Alt-click an item link in
  chat, or a key binding over any item. All open the book (or the plain window with `/sb book off`).
- **Plain window** (`/sb classic`): search items by name, see every source,
  and click one to get a waypoint to the nearest spawn (TomTom's arrow if it's installed, else the
  game's map pin). Vendors are sorted nearest first.
- **Recipe view**: reagents with how many you have (bags and bank), and a plan for crafting it
  N times: which intermediate items to craft first and what you still need to get.
- **Learns as you play**: it remembers what you loot from what. Creatures and zones that are new
  in Forever show up as "You looted it from", and known sources gain your own observed drop rate.

Commands: `/sb` (search), `/sb <item name, link or ID>`, `/sb tooltip|mobs|record [on|off]`,
`/sb forget`, `/sb help`. There's also a key binding: "Look up the hovered item".

## Where the data comes from

| Data | Source |
|---|---|
| Recipes, reagents, skill ranks, recipe items | The Forever client's own tables (wago.tools exports of build 1.60.1.70862). |
| Drops, chances, skinning, gathering, vendors, spawns | The [VMaNGOS](https://github.com/vmangos/core) world database (patch 1.12 content). |
| Zones and map coordinates | Spawn positions placed on the Forever maps using the terrain's area IDs from your own install. |

Forever is built on vanilla, so item, creature and object IDs match; drop chances are the
emulator's, not Blizzard's, and Forever's new zones aren't in it. That's what the loot recorder
covers.

## Repository layout

| Path | What it is |
|---|---|
| `Sourcebook/` | The addon (MIT). `Data/Recipes.lua` is generated. |
| `Sourcebook_Loot/` | The generated loot data addon (GPL-2.0, because it is derived from VMaNGOS's database). |
| `tools/build_data.py` | Rebuilds both data files: `python tools/build_data.py [--build X] [--wow "D:\World of Warcraft"]`. |
| `tools/areas.py`, `tools/casc.py` | Read the terrain's area IDs from the local game install. |
| `tools/book/` | The book's art: `textures.py` (parchment, leather, tooling), `render_book.py` (Blender scene: the spread, the cover, the page turn with motion blur and its shadow), `pack.py` (crops and packs frames into the addon's `Media/` and writes `BookArt.lua`). |
| `tests/` | Lua 5.1 tests through lupa, plus a smoke test that loads the whole addon against stubs. |

Rebuilding the book art (Blender 5.2, a CUDA/OptiX GPU; the turn takes about 25 minutes):

```
python tools/book/textures.py
blender -b -P tools/book/render_book.py -- spread --samples 256
blender -b -P tools/book/render_book.py -- cover --samples 128
blender -b -P tools/book/render_book.py -- turn --frames 24 --samples 16 --scale 0.7 --subs 6
python tools/book/pack.py
```

```
python -m pip install --target .pylibs lupa
python tests/run.py
tools/package.sh      # dist/Sourcebook-<version>.zip
```

## License

`Sourcebook/` and the tools are MIT (see `LICENSE`). `Sourcebook_Loot/` is GPL-2.0 (see
`Sourcebook_Loot/COPYING`).
