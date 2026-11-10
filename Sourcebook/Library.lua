-- Sourcebook: the book's index. Browse every known item by category, sort and search, a page at
-- a time. Pure; reads SourcebookLoot.names and SourcebookLoot.meta.

local _, ns = ...

local Library = {}
ns.Library = Library

Library.CATEGORIES = { "all", "reagent", "recipe", "gear", "consumable", "other" }
Library.CATEGORY_LABEL = {
	all = "All",
	reagent = "Reagents",
	recipe = "Recipes",
	gear = "Gear",
	consumable = "Consumables",
	other = "Other",
}
Library.SORTS = { "name", "quality", "level", "sources" }
Library.SORT_LABEL = { name = "Name", quality = "Quality", level = "Level", sources = "Most sources" }

local function Loot()
	return ns.Loot or SourcebookLoot
end

local metaCache = {}

-- { class, subclass, quality, itemLevel, requiredLevel } or nil.
function Library.Meta(itemID)
	local m = metaCache[itemID]
	if m == nil then
		local loot = Loot()
		local s = loot and loot.meta and loot.meta[itemID]
		if s then
			local c, sc, q, il, rl = s:match("^(%-?%d+):(%-?%d+):(%d+):(%d+):(%d+)$")
			m = { class = tonumber(c), subclass = tonumber(sc), quality = tonumber(q), itemLevel = tonumber(il),
				requiredLevel = tonumber(rl) }
		else
			m = false
		end
		metaCache[itemID] = m
	end
	return m or nil
end

-- Item class IDs: 0 consumable, 2 weapon, 4 armor, 5 reagent, 7 trade goods, 9 recipe.
function Library.Category(itemID)
	local m = Library.Meta(itemID)
	if not m then
		return "other"
	end
	local c = m.class
	if c == 5 or c == 7 then
		return "reagent"
	elseif c == 9 then
		return "recipe"
	elseif c == 2 or c == 4 then
		return "gear"
	elseif c == 0 then
		return "consumable"
	end
	return "other"
end

local sourceCount = {}

-- How many sources the data lists for an item (the "#d638" style totals count in full).
function Library.SourceCount(itemID)
	local n = sourceCount[itemID]
	if not n then
		n = 0
		local loot = Loot()
		local s = loot and loot.item[itemID]
		if s then
			local totals = {}
			for kind, count in s:gmatch("#(%a)(%d+)") do
				totals[kind] = tonumber(count)
			end
			local listed = {}
			for kind in s:gmatch("[;]?(%a)%d+:") do
				listed[kind] = (listed[kind] or 0) + 1
			end
			for kind, c in pairs(listed) do
				n = n + math.max(c, totals[kind] or 0)
			end
		end
		sourceCount[itemID] = n
	end
	return n
end

local function Words(query)
	local words = {}
	if query then
		for w in query:lower():gmatch("%S+") do
			words[#words + 1] = w
		end
	end
	return words
end

local SORTERS = {
	name = function(a, b)
		if a.lower ~= b.lower then
			return a.lower < b.lower
		end
		return a.id < b.id
	end,
	quality = function(a, b)
		if a.quality ~= b.quality then
			return a.quality > b.quality
		end
		if a.lower ~= b.lower then
			return a.lower < b.lower
		end
		return a.id < b.id
	end,
	level = function(a, b)
		if a.level ~= b.level then
			return a.level > b.level
		end
		if a.lower ~= b.lower then
			return a.lower < b.lower
		end
		return a.id < b.id
	end,
	sources = function(a, b)
		if a.sources ~= b.sources then
			return a.sources > b.sources
		end
		if a.lower ~= b.lower then
			return a.lower < b.lower
		end
		return a.id < b.id
	end,
}

-- Every item matching a query (all words, any order) and a category, sorted. Returns item IDs.
-- With a query, exact names come first, then names starting with it, before the chosen order.
function Library.Browse(query, category, sortKey)
	local loot = Loot()
	local out = {}
	if not (loot and loot.names) then
		return out
	end
	category = category or "all"
	local sorter = SORTERS[sortKey or "name"] or SORTERS.name
	local words = Words(query)
	local q = table.concat(words, " ")
	local rows = {}
	for id, name in pairs(loot.names) do
		local lower = name:lower()
		local match = true
		for _, w in ipairs(words) do
			if not lower:find(w, 1, true) then
				match = false
				break
			end
		end
		if match and (category == "all" or Library.Category(id) == category) then
			local m = Library.Meta(id)
			rows[#rows + 1] = {
				id = id,
				lower = lower,
				rank = (q ~= "" and ((lower == q and 0) or (lower:sub(1, #q) == q and 1) or 2)) or 2,
				quality = m and m.quality or 0,
				level = m and math.max(m.requiredLevel, 0) * 1000 + m.itemLevel or 0,
				sources = sortKey == "sources" and Library.SourceCount(id) or 0,
			}
		end
	end
	table.sort(rows, function(a, b)
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		return sorter(a, b)
	end)
	for i, r in ipairs(rows) do
		out[i] = r.id
	end
	return out
end

-- One page of a list: returns the slice, the page actually shown (clamped) and the page count.
function Library.Page(list, perPage, page)
	local pages = math.max(1, math.ceil(#list / perPage))
	page = math.min(math.max(1, page or 1), pages)
	local slice = {}
	for i = (page - 1) * perPage + 1, math.min(#list, page * perPage) do
		slice[#slice + 1] = list[i]
	end
	return slice, page, pages
end

-- Flows elements onto pages. heights[i] is each element's height, keep[i] true when element i
-- must sit on the same page as the one after it (a section header and its first row).
-- Returns pageOf[i] (1-based page numbers) and the page count. An element taller than a page
-- gets a page to itself.
function Library.Flow(heights, capacity, keep)
	keep = keep or {}
	local pageOf = {}
	local page, used = 1, 0
	local i = 1
	while i <= #heights do
		-- A header and whatever it must stay with move as one block.
		local j, block = i, heights[i]
		while keep[j] and j < #heights do
			j = j + 1
			block = block + heights[j]
		end
		if used > 0 and used + block > capacity then
			page, used = page + 1, 0
		end
		for k = i, j do
			pageOf[k] = page
		end
		used = used + block
		i = j + 1
	end
	return pageOf, #heights > 0 and page or 0
end

function Library.Reset()
	metaCache, sourceCount = {}, {}
end
