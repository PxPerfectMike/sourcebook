local Sources, Format = ns.Sources, ns.Format

local function Group(info, key)
	for _, g in ipairs(info.groups) do
		if g.key == key then
			return g
		end
	end
end

T("Copper Ore: veins first, then drops, with names and zones", function()
	local info = Sources.ForItem(2770)
	ok(info.any)
	eq(info.groups[1].key, "M")
	local veins = Group(info, "M")
	eq(veins.label, "Mined from")
	eq(veins.entries[1].name, "Copper Vein")
	ok(veins.entries[1].chance >= 0.99, "Copper Vein always gives ore")
	ok(#veins.entries[1].locations > 5, "Copper Vein is in many zones")
	local drops = Group(info, "d")
	ok(drops.total > #drops.entries, "drop total counts the unlisted creatures")
	ok(drops.entries[1].name ~= nil)
	for _, e in ipairs(drops.entries) do
		ok(e.id ~= 1731, "Copper Vein loot leaked onto creature 1731 (Goblin Craftsman)")
		ok(e.chance < 0.9, e.name .. " drops Copper Ore at " .. e.chance)
	end
	eq(#veins.entries, 1, "the Copper Vein IDs merge into one row")
end)

T("Created counts come through: Smelt Bronze makes 2, Crafted Light Shot 200", function()
	eq(ns.Codec.Recipe(2659).count, 2)
	eq(ns.Codec.Recipe(3920).count, 200)
end)

T("Light Leather is skinned; Linen Cloth is pickpocketed", function()
	ok(Group(Sources.ForItem(2318), "k"))
	ok(Group(Sources.ForItem(2589), "p"))
end)

T("Vendor-only reagent lists its vendors", function()
	local vendors = Group(Sources.ForItem(2880), "v") -- Weak Flux
	ok(vendors and #vendors.entries > 10)
	eq(vendors.label, "Sold by")
end)

T("Unknown item has no groups", function()
	local info = Sources.ForItem(999999999)
	eq(info.any, false)
	eq(info.groups, {})
end)

T("Learned loot annotates a known source and adds an unknown one", function()
	local db = ns.Learned.Init({})
	for _ = 1, 5 do
		ns.Learned.Record(db, "d", 6, nil, { [4536] = true }, nil) -- Kobold Vermin, Shiny Red Apple
	end
	ns.Learned.Record(db, "d", 999999, "New Forever Beast", { [4536] = true }, { m = 2482, x = 10, y = 20 })
	local info = Sources.ForItem(4536, db)
	local drops = Group(info, "d")
	local vermin
	for _, e in ipairs(drops.entries) do
		if e.id == 6 then
			vermin = e
		end
	end
	if vermin then
		eq(vermin.seen.rate, 1)
	end
	local learned = Group(info, "learned")
	ok(learned, "unknown source becomes its own group")
	eq(info.groups[1].key, "learned")
	eq(learned.entries[1].name, "New Forever Beast")
	eq(learned.entries[1].m, 2482)
end)

T("Distance, SortByDistance and Target", function()
	local near = { name = "near", locations = { { map = 1429, count = 1, points = { { 50, 40 } } } } }
	local far = { name = "far", locations = { { map = 1429, count = 1, points = { { 10, 10 } } } } }
	local away = { name = "away", locations = { { map = 1436, count = 3, points = { { 1, 1 } } } } }
	local inside = { name = "inside", locations = { { instance = 36, count = 2 } } }
	eq(Sources.Distance(near, 1429, 50, 40), 0)
	eq(Sources.Distance(away, 1429, 50, 40), nil)
	local list = Sources.SortByDistance({ away, far, inside, near }, 1429, 50, 41)
	eq(list[1].name, "near")
	eq(list[2].name, "far")
	eq(list[3].name, "away")
	eq(list[4].name, "inside")
	eq(Sources.Target(near, 1429, 0, 0), { map = 1429, x = 50, y = 40 })
	eq(Sources.Target(away, 1429, 50, 40), { map = 1436, x = 1, y = 1 })
	eq(Sources.Target(inside, 1429, 50, 40), nil)
	eq(Sources.Target({ m = 2482, x = 3, y = 4 }), { map = 2482, x = 3, y = 4 })
	local two = { locations = { { map = 1436, count = 1, points = { { 5, 5 } } }, { map = 1429, count = 1, points = { { 60, 60 }, { 51, 41 } } } } }
	eq(Sources.Target(two, 1429, 50, 40), { map = 1429, x = 51, y = 41 })
end)

T("Search ranks exact and prefix matches first", function()
	local ids = Sources.Search("copper ore", 5)
	eq(ids[1], 2770)
	local bars = Sources.Search("COPPER", 50)
	ok(#bars > 3)
	eq(Sources.Search("", 5), {})
	eq(Sources.Search("zzzqqq", 5), {})
	eq(#Sources.Search("cloth", 3), 3)
end)

T("NpcDrops lists notable items", function()
	local drops = Sources.NpcDrops(1731) -- Goblin Craftsman
	ok(#drops > 0)
	ok(drops[1].item and drops[1].chance)
	eq(Sources.NpcDrops(999999999), {})
end)

T("Format.Chance", function()
	eq(Format.Chance(1), "100%")
	eq(Format.Chance(0.25), "25%")
	eq(Format.Chance(0.052), "5.2%")
	eq(Format.Chance(0.05), "5%")
	eq(Format.Chance(0.004), "0.4%")
	eq(Format.Chance(0.0001), "<0.1%")
	eq(Format.Chance(nil), "")
end)

T("Format.Entry phrases NPCs, vendors, containers and learned sources", function()
	local npcGroup = { key = "d" }
	local text, stat = Format.Entry(npcGroup, { id = 6, name = "Kobold Vermin", levelMin = 1, levelMax = 2, rank = 0,
		chance = 0.5, min = 1, max = 3, locations = { { map = 1429, count = 33 } } })
	eq(text, "Kobold Vermin (1-2, Map 1429)")
	eq(stat, "1-3x 50%")
	text, stat = Format.Entry({ key = "v" }, { id = 1, name = "Tharynn", levelMin = 30, levelMax = 30, limited = true,
		locations = { { map = 1453, count = 1 }, { map = 1429, count = 1 } } })
	eq(text, "Tharynn (Map 1453 +1)")
	eq(stat, "limited")
	text = Format.Entry({ key = "d" }, { id = 1716, name = "Bazil Thredd", levelMin = 29, levelMax = 29, rank = 1,
		chance = 0.2, min = 1, max = 1, quest = true, locations = { { instance = 34, count = 1 } } })
	eq(text, "Bazil Thredd (29, Elite, Instance 34)")
	text, stat = Format.Entry({ key = "learned" }, { kind = "d", id = 9, name = "Beast", hits = 2, loots = 3, m = 2482 })
	eq(text, "Beast (Map 2482)")
	eq(stat, "2/3")
	text, stat = Format.Entry({ key = "c" }, { id = 2589, chance = 0.25 })
	eq(text, "Linen Cloth")
	eq(stat, "25%")
end)

T("Format.ItemLines for a reagent includes sources and recipes", function()
	local info = Sources.ForItem(2770)
	local craft = { createdBy = ns.Craft.CreatedBy(2770), usedIn = ns.Craft.UsedIn(2770), teaches = ns.Craft.Teaches(2770) }
	local lines = Format.ItemLines(info, craft, {})
	local all = {}
	for _, l in ipairs(lines) do
		all[#all + 1] = l.left .. " | " .. l.right
	end
	local text = table.concat(all, "\n")
	ok(text:find("Mined from:"), text)
	ok(text:find("Copper Vein"), text)
	ok(text:find("Reagent for"), text)
	ok(text:find("Mining"), text)
	local full = Format.ItemLines(info, craft, { full = true })
	ok(#full > #lines, "Shift shows more")
end)

T("Format.ItemLines for a recipe item says what it teaches", function()
	local recipeItem, spell = next(ns.RecipeItems)
	local craft = { createdBy = {}, usedIn = {}, teaches = ns.Craft.Teaches(recipeItem) }
	local lines = Format.ItemLines({ groups = {} }, craft, { knows = function(s)
		return s == spell
	end })
	ok(lines[1].left:find("^Teaches: "))
	eq(lines[2].left, "  You know this recipe")
end)
