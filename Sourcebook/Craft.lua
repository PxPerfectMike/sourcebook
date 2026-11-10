-- Sourcebook: recipe lookups (what makes an item, what uses it, what a recipe item teaches) and
-- the crafting plan (what to craft first and what you still need to get).

local _, ns = ...

local Craft = {}
ns.Craft = Craft

local createdBy, usedIn

local function Index()
	if createdBy then
		return
	end
	createdBy, usedIn = {}, {}
	for spell, t in pairs(ns.Recipes or {}) do
		local item = t[2]
		if item and item > 0 then
			createdBy[item] = createdBy[item] or {}
			table.insert(createdBy[item], spell)
		end
		local seen = {}
		for i = 8, #t - 1, 2 do
			local reagent = t[i]
			if not seen[reagent] then
				seen[reagent] = true
				usedIn[reagent] = usedIn[reagent] or {}
				table.insert(usedIn[reagent], spell)
			end
		end
	end
end

function Craft.Reset()
	createdBy, usedIn = nil, nil
end

local function Recipes(spells)
	local out = {}
	for _, spell in ipairs(spells or {}) do
		out[#out + 1] = ns.Codec.Recipe(spell)
	end
	return out
end

function Craft.CreatedBy(itemID)
	Index()
	local list = Recipes(createdBy[itemID])
	table.sort(list, function(a, b)
		if a.orange ~= b.orange then
			return a.orange < b.orange
		end
		return a.spell < b.spell
	end)
	return list
end

function Craft.UsedIn(itemID)
	Index()
	local list = Recipes(usedIn[itemID])
	table.sort(list, function(a, b)
		if a.skill ~= b.skill then
			return a.skill < b.skill
		end
		if a.orange ~= b.orange then
			return a.orange < b.orange
		end
		return a.spell < b.spell
	end)
	return list
end

function Craft.Teaches(itemID)
	local spell = ns.RecipeItems and ns.RecipeItems[itemID]
	return spell and ns.Codec.Recipe(spell) or nil
end

-- Plan crafting spellID `times` times. have(itemID) -> count owned. Returns
-- { steps = { { spell, crafts }, ... } (craft these in order), raw = { { item, need, have, missing }, ... } }.
-- A reagent the player is short of is crafted too when a recipe of the same profession makes it.
function Craft.Plan(spellID, times, have)
	local steps, stepIndex = {}, {}
	local raw, rawIndex = {}, {}
	local used = {} -- itemID -> how many owned items are already spoken for

	local function Take(item, need)
		local owned = have(item) or 0
		local free = math.max(0, owned - (used[item] or 0))
		local take = math.min(free, need)
		used[item] = (used[item] or 0) + take
		return take
	end

	local function AddRaw(item, need, got)
		local line = rawIndex[item]
		if not line then
			line = { item = item, need = 0, have = 0, missing = 0 }
			rawIndex[item] = line
			raw[#raw + 1] = line
		end
		line.need = line.need + need
		line.have = line.have + got
		line.missing = line.need - line.have
	end

	local function AddStep(spell, crafts)
		local step = stepIndex[spell]
		if step then
			step.crafts = step.crafts + crafts
			-- keep it after anything it depends on: move to the end
			for i, s in ipairs(steps) do
				if s == step then
					table.remove(steps, i)
					break
				end
			end
			steps[#steps + 1] = step
		else
			step = { spell = spell, crafts = crafts }
			stepIndex[spell] = step
			steps[#steps + 1] = step
		end
	end

	local expanding = {}
	local function Walk(recipe, crafts, depth)
		for _, reagent in ipairs(recipe.reagents) do
			local need = reagent.count * crafts
			local got = Take(reagent.item, need)
			local missing = need - got
			local sub
			if missing > 0 and depth < 5 and not expanding[reagent.item] then
				for _, r in ipairs(Craft.CreatedBy(reagent.item)) do
					if r.skill == recipe.skill then
						sub = r
						break
					end
				end
			end
			if sub then
				local subCrafts = math.ceil(missing / math.max(1, sub.count))
				if got > 0 then
					AddRaw(reagent.item, got, got)
				end
				expanding[reagent.item] = true
				Walk(sub, subCrafts, depth + 1)
				expanding[reagent.item] = nil
				AddStep(sub.spell, subCrafts)
			else
				AddRaw(reagent.item, need, got)
			end
		end
	end

	local top = ns.Codec.Recipe(spellID)
	if top then
		expanding[top.item] = true
		Walk(top, times, 0)
		AddStep(spellID, times)
	end
	table.sort(raw, function(a, b)
		return a.item < b.item
	end)
	return { steps = steps, raw = raw }
end
