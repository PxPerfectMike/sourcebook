# In-game checks (WoW Forever 1.60.1)

The offline tests run the real Lua against stubs. These depend on the live client and still need
checking in game. Mark each one when confirmed.

**Restart the game client fully** after installing or updating (not just `/reload`): the client
only discovers new addon files and textures at launch. A missing `BookArt.lua` or texture makes
`/sb` silently fall back to the plain window.

| # | Check | How | Expected |
|---|---|---|---|
| 1 | Loads without errors | Log in with Sourcebook and Sourcebook_Loot enabled, `/console scriptErrors 1` | No Lua errors. |
| 2 | Item tooltip | Hover Linen Cloth, Copper Ore, Light Leather in bags | "Dropped by / Mined from / Skinned from" with real zone names (not "Map 1413"), "Reagent for N recipes". |
| 3 | Shift expands | Hold Shift over the same items | More lines appear without moving the mouse (`RefreshData`). |
| 4 | Recipe items | Hover any "Pattern:" / "Plans:" item | "Teaches: ..." with the profession and rank; green if known. |
| 5 | Creature tooltip | Mouse over a mob (e.g. a Kobold in Elwynn) | "Notable drops:" with item names. Also check no errors in combat (secret values). |
| 6 | Lookup window | `/sb`, type "copper" | Results list with icons; clicking opens the item page. |
| 7 | Waypoint | On the Copper Ore page, click Copper Vein | TomTom arrow (or map pin + super-track arrow without TomTom) to a vein in your zone if there are any. |
| 8 | Alt-click link | Alt-click an item link in chat | The item page opens. |
| 9 | Recipe page | From Copper Bar, click Smelt Copper | Reagent counts match your bags+bank; "One more" raises the plan count. |
| 10 | Zone names for instances | Look up Bazil Thredd's drops (an item from The Stockade) | Instance shown by name (`GetRealZoneText(mapID)`), not "Instance 34". |
| 11 | Loot recording | Kill and loot 2-3 mobs, then skin one; `/dump SourcebookDB.learned.src` | One `d<npcID>` per corpse with k counts; the skinned one also has `k<npcID>`. |
| 12 | Forever-only content | Loot something in Mount Hyjal / Riverglades / Zephras Isle | The item's tooltip shows "You looted it from ..." with the zone. |
| 13 | Key binding | Bind "Look up the hovered item" (Key Bindings > AddOns) and press it over an item | The item page opens. |
| 14 | Profession names | Any recipe line | Uses the client's localized profession name if `C_TradeSkillUI.GetTradeSkillDisplayName` answers; English fallback otherwise. |

## The book

| # | Check | How | Expected |
|---|---|---|---|
| 15 | Opening | `/sb` | Dark vignette fades in, the closed book settles, runes pulse, a glint crosses the gold, the cover swings open (no warping along the strips), sparks and light from the pages, the book slides to center, ink writes in. |
| 16 | Size | Different UI scales | The book fills most of the screen height without overflowing the width. |
| 17 | Page turn | Click any result | The page lifts from the corner, curls over with its shadow, lands; no jump at the start or end, no double edges mid-turn. Sound plays. |
| 18 | Ink | Any spread | Text writes left to right, line after line (`SetAlphaGradient`); nothing stays half-written. |
| 19 | Search | Type in the index | Results rewrite as you type without losing focus; title and filters don't flicker. |
| 20 | Filters and sort | Click the categories and sort words | List rewrites in place; the selected word is underlined. |
| 21 | Ribbons and corner | Hover and click the red and gold ribbons and the top-right corner | Index, back, close; tooltips name them. |
| 22 | Escape, click outside | With the book open | Both close it with the fade. |
| 23 | Frame rate | Turn pages quickly | No hitching; turns queue instead of overlapping. |
| 24 | Memory | `/run UpdateAddOnMemoryUsage() print(GetAddOnMemoryUsage("Sourcebook"))` | Reasonable; the turn atlases are the big cost (video memory). |

## Navigation

| # | Check | How | Expected |
|---|---|---|---|
| 25 | Back from an item | Open the book, click an item, then click "‹ Back" (and again with Backspace, right-click, mouse 4) | The page turns back to the index you came from, same search and page. |
| 26 | Nav row | Any spread | Back/Index on the left page, trail/Forward on the right, below the head ornament; faded when unavailable. |
| 27 | Trail | Go index, item, recipe, item; click the first item in the trail | One turn straight back to it; Forward then walks the trail. |
| 28 | Paging | Index: wheel, Left/Right, Page Up/Down, the footer links | Turns pages; footer shows page numbers; "page X of Y" in the count line. |
| 29 | Keys pass through | With the book open, walk with WASD, open bags | Movement and other keys work; only the book's keys are used. |
| 30 | Combat | Enter combat with the book open, press Backspace | Nothing happens to the book; no "action blocked" message. |
| 31 | Search keys | Press Ctrl+F on any spread; type; Enter; Escape twice | Jumps to the index search, Enter opens the top match, Escape clears then unfocuses. |
| 32 | Reopen | Navigate somewhere, close, `/sb` | Reopens on the same page with Back working. |
