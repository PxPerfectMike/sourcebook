local Codec, Craft = ns.Codec, ns.Craft

T("ParseSources reads kinds, chances, counts, flags and totals", function()
	local list, totals = Codec.ParseSources("d6:1189;o75293:833:2:10;d2376:4500:q;v66:10000:l;#d638;#v109")
	eq(#list, 4)
	eq(list[1], { kind = "d", id = 6, chance = 0.1189, min = 1, max = 1, quest = false, limited = false })
	eq(list[2], { kind = "o", id = 75293, chance = 0.0833, min = 2, max = 10, quest = false, limited = false })
	eq(list[3].quest, true)
	eq(list[4].limited, true)
	eq(totals, { d = 638, v = 109 })
	eq({ Codec.ParseSources(nil) }, { {}, {} })
	eq({ Codec.ParseSources("") }, { {}, {} })
end)

T("ParseSources reads a quest drop with a stack size", function()
	local list = Codec.ParseSources("d1:5000:2:3:q")
	eq(list[1].min, 2)
	eq(list[1].max, 3)
	eq(list[1].quest, true)
end)

T("ParseNpc and ParseLocations", function()
	local npc = Codec.ParseNpc(SourcebookLoot.npc[6])
	eq(npc.name, "Kobold Vermin")
	eq(npc.levelMin, 1)
	eq(npc.levelMax, 2)
	eq(npc.rank, 0)
	eq(npc.locations[1].map, 1429)
	eq(npc.locations[1].count, 33)
	eq(npc.locations[1].points[1], { 49, 36.3 })
	local boss = Codec.ParseNpc("Bazil Thredd|29|1|i34:1")
	eq(boss.levelMin, 29)
	eq(boss.levelMax, 29)
	eq(boss.locations, { { instance = 34, count = 1 } })
	eq(Codec.ParseNpc("Nowhere Man|5|0|").locations, {})
	eq(Codec.ParseNpc(nil), nil)
	eq(Codec.ParseLocations(""), {})
end)

T("ParseObject and ParseDrops", function()
	local vein = Codec.ParseObject(SourcebookLoot.obj[1731])
	eq(vein.name, "Copper Vein")
	eq(vein.kind, "M")
	ok(#vein.locations > 5)
	eq(Codec.ParseObject(nil), nil)
	eq(Codec.ParseDrops("4306:2953;2592:467"), { { item = 4306, chance = 0.2953 }, { item = 2592, chance = 0.0467 } })
	eq(Codec.ParseDrops(nil), {})
end)

T("Recipe decodes Smelt Copper", function()
	eq(Codec.Recipe(2657), { spell = 2657, skill = 186, item = 2840, count = 1, orange = 1, yellow = 25, gray = 70,
		learnedFrom = 0, reagents = { { item = 2770, count = 1 } } })
	eq(Codec.Recipe(1), nil)
end)

T("CreatedBy, UsedIn and Teaches on real data", function()
	local made = Craft.CreatedBy(2840)
	eq(made[1].spell, 2657)
	local found = false
	for _, r in ipairs(Craft.UsedIn(2770)) do
		found = found or r.spell == 2657
	end
	ok(found, "Copper Ore is used by Smelt Copper")
	eq(Craft.CreatedBy(999999999), {})
	local item, spell = next(ns.RecipeItems)
	eq(Craft.Teaches(item).spell, spell)
	eq(Craft.Teaches(2770), nil)
end)

-- A fake recipe book: 10 ore -> bar (skill 1); widget = 3 bars + 1 thread (skill 1); thread is
-- made by skill 2, so it is bought, not crafted. Loop: a <- b <- a.
local fake = {
	[100] = { 1, 20, 1, 1, 1, 1, 0, 10, 2 }, -- bar from 2 ore
	[101] = { 1, 30, 1, 1, 1, 1, 0, 20, 3, 40, 1 }, -- widget from 3 bars + 1 thread
	[102] = { 2, 40, 2, 1, 1, 1, 0, 41, 1 }, -- 2 thread from 1 fiber (other skill)
	[103] = { 1, 50, 1, 1, 1, 1, 0, 20, 1, 30, 1 }, -- gadget: 1 bar + 1 widget (bar used twice)
	[104] = { 3, 60, 1, 1, 1, 1, 0, 61, 1 }, -- loop a from b
	[105] = { 3, 61, 1, 1, 1, 1, 0, 60, 1 }, -- loop b from a
}

local function WithFake(fn)
	local real = ns.Recipes
	ns.Recipes = fake
	Craft.Reset()
	local good, err = pcall(fn)
	ns.Recipes = real
	Craft.Reset()
	if not good then
		error(err, 0)
	end
end

local function Haves(t)
	return function(id)
		return t[id] or 0
	end
end

T("Plan crafts intermediates of the same profession first", function()
	WithFake(function()
		local plan = Craft.Plan(101, 2, Haves({ [20] = 1, [10] = 3 }))
		-- need 6 bars, have 1 -> craft 5 bars from 10 ore (have 3); need 2 thread, other skill -> raw
		eq(plan.steps, { { spell = 100, crafts = 5 }, { spell = 101, crafts = 2 } })
		eq(plan.raw, {
			{ item = 10, need = 10, have = 3, missing = 7 },
			{ item = 20, need = 1, have = 1, missing = 0 },
			{ item = 40, need = 2, have = 0, missing = 2 },
		})
	end)
end)

T("Plan does not count the same owned items twice", function()
	WithFake(function()
		local plan = Craft.Plan(103, 1, Haves({ [20] = 2 }))
		-- gadget needs 1 bar directly and 3 bars via the widget: 2 owned, 2 crafted
		eq(plan.steps, { { spell = 100, crafts = 2 }, { spell = 101, crafts = 1 }, { spell = 103, crafts = 1 } })
		eq(plan.raw, {
			{ item = 10, need = 4, have = 0, missing = 4 },
			{ item = 20, need = 2, have = 2, missing = 0 },
			{ item = 40, need = 1, have = 0, missing = 1 },
		})
	end)
end)

T("Plan with everything owned has no extra steps", function()
	WithFake(function()
		local plan = Craft.Plan(101, 1, Haves({ [20] = 9, [40] = 9 }))
		eq(plan.steps, { { spell = 101, crafts = 1 } })
		eq(plan.raw[1], { item = 20, need = 3, have = 3, missing = 0 })
	end)
end)

T("Plan stops at a loop", function()
	WithFake(function()
		local plan = Craft.Plan(104, 1, Haves({}))
		eq(plan.steps, { { spell = 105, crafts = 1 }, { spell = 104, crafts = 1 } })
		eq(plan.raw, { { item = 60, need = 1, have = 0, missing = 1 } })
	end)
end)

T("Plan for an unknown recipe is empty", function()
	eq(Craft.Plan(1, 1, Haves({})), { steps = {}, raw = {} })
end)
