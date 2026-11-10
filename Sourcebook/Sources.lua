-- Sourcebook: everything known about where an item comes from, as display-ready groups.

local _, ns = ...

local Sources = {}
ns.Sources = Sources

-- Group order and labels. Object sources split by what the object is.
Sources.ORDER = { "learned", "M", "H", "F", "d", "k", "p", "C", "O", "c", "f", "v" }
Sources.LABEL = {
	learned = "You looted it from",
	M = "Mined from",
	H = "Gathered from",
	F = "Fishing pool",
	d = "Dropped by",
	k = "Skinned from",
	p = "Pickpocketed from",
	C = "Found in",
	O = "Found in",
	c = "Inside",
	f = "Fished in",
	v = "Sold by",
}
local NPC_KINDS = { d = true, k = true, p = true, v = true }

local function Loot()
	return ns.Loot or SourcebookLoot
end

local npcCache, objCache = {}, {}

function Sources.Npc(id)
	local cached = npcCache[id]
	if cached == nil then
		local loot = Loot()
		cached = loot and ns.Codec.ParseNpc(loot.npc[id]) or false
		npcCache[id] = cached
	end
	return cached or nil
end

function Sources.Object(id)
	local cached = objCache[id]
	if cached == nil then
		local loot = Loot()
		cached = loot and ns.Codec.ParseObject(loot.obj[id]) or false
		objCache[id] = cached
	end
	return cached or nil
end

function Sources.Reset()
	npcCache, objCache = {}, {}
end

local function MergeInto(target, e)
	target.chance = math.max(target.chance or 0, e.chance or 0)
	target.max = math.max(target.max or 1, e.max or 1)
	target.min = math.min(target.min or 1, e.min or 1)
	target.quest = target.quest and e.quest
	target.levelMin = target.levelMin and e.levelMin and math.min(target.levelMin, e.levelMin) or target.levelMin
	target.levelMax = target.levelMax and e.levelMax and math.max(target.levelMax, e.levelMax) or target.levelMax
	local merged, index = {}, {}
	for _, list in ipairs({ target.locations or {}, e.locations or {} }) do
		for _, loc in ipairs(list) do
			local key = loc.instance and ("i" .. loc.instance) or loc.map
			local into = index[key]
			if into then
				into.count = into.count + loc.count
				for _, p in ipairs(loc.points or {}) do
					into.points[#into.points + 1] = p
				end
			else
				into = { instance = loc.instance, map = loc.map, count = loc.count, points = loc.points and { unpack(loc.points) } or nil }
				index[key] = into
				merged[#merged + 1] = into
			end
		end
	end
	-- Open-world zones by spawn count, instances last (same order the data uses).
	table.sort(merged, function(a, b)
		if (a.instance == nil) ~= (b.instance == nil) then
			return a.instance == nil
		end
		return a.count > b.count
	end)
	target.locations = merged
end

-- learnedDb: SourcebookDB.learned or nil. Returns
-- { groups = { { key, label, entries, total }, ... }, any = bool }.
-- Each entry is the Codec source plus: name, levelMin, levelMax, rank, locations (NPCs and
-- objects), objKind (objects). Learned entries carry hits, loots, rate, m, x, y instead of chance.
function Sources.ForItem(itemID, learnedDb)
	local byKey = {}
	local loot = Loot()
	local list, totals = ns.Codec.ParseSources(loot and loot.item[itemID])
	local staticIds = {}
	for _, e in ipairs(list) do
		local key = e.kind
		if NPC_KINDS[e.kind] then
			local npc = Sources.Npc(e.id)
			if npc then
				e.name, e.levelMin, e.levelMax, e.rank, e.locations = npc.name, npc.levelMin, npc.levelMax, npc.rank, npc.locations
			end
		elseif e.kind == "o" then
			local obj = Sources.Object(e.id)
			if obj then
				e.name, e.objKind, e.locations = obj.name, obj.kind, obj.locations
				key = obj.kind
			else
				key = "O"
			end
		end
		local group = byKey[key]
		if not group then
			group = { key = key, label = Sources.LABEL[key], entries = {}, total = 0, byName = {} }
			byKey[key] = group
		end
		local same = e.name and group.byName[e.name]
		if same then
			-- Several IDs with one name (three kinds of "Copper Vein"): one row, all locations.
			MergeInto(same, e)
			staticIds[e.kind .. e.id] = same
		else
			staticIds[e.kind .. e.id] = e
			group.entries[#group.entries + 1] = e
			group.total = group.total + 1
			if e.name then
				group.byName[e.name] = e
			end
		end
	end
	for kind, n in pairs(totals) do
		if kind ~= "o" and byKey[kind] then
			byKey[kind].total = math.max(byKey[kind].total, n)
		end
	end
	if learnedDb then
		for _, l in ipairs(ns.Learned.ForItem(learnedDb, itemID)) do
			local known = staticIds[l.kind .. l.id] or (l.kind == "k" and staticIds["d" .. l.id])
			if known then
				known.seen = l
			else
				local group = byKey.learned
				if not group then
					group = { key = "learned", label = Sources.LABEL.learned, entries = {}, total = 0 }
					byKey.learned = group
				end
				if not l.name and NPC_KINDS[l.kind] then
					local npc = Sources.Npc(l.id)
					l.name = npc and npc.name
				end
				group.entries[#group.entries + 1] = l
				group.total = group.total + 1
			end
		end
	end
	local result = { groups = {}, any = false }
	for _, key in ipairs(Sources.ORDER) do
		local group = byKey[key]
		if group then
			result.groups[#result.groups + 1] = group
			result.any = true
		end
	end
	return result
end

-- Squared distance from the player to the nearest known point of an entry on the player's map,
-- or nil when it has none there. Map percent units; good enough for "which vendor is closest".
function Sources.Distance(entry, map, px, py)
	if not (map and px) then
		return nil
	end
	if entry.m == map and entry.x then
		return (entry.x - px) ^ 2 + (entry.y - py) ^ 2
	end
	local best
	for _, loc in ipairs(entry.locations or {}) do
		if loc.map == map and loc.points then
			for _, p in ipairs(loc.points) do
				local d = (p[1] - px) ^ 2 + (p[2] - py) ^ 2
				if not best or d < best then
					best = d
				end
			end
		end
	end
	return best
end

-- Sorts a group's entries nearest first (entries on other maps keep their order after them).
function Sources.SortByDistance(entries, map, px, py)
	local keyed = {}
	for i, e in ipairs(entries) do
		keyed[i] = { e = e, d = Sources.Distance(e, map, px, py), i = i }
	end
	table.sort(keyed, function(a, b)
		if a.d and b.d then
			return a.d < b.d
		end
		if a.d or b.d then
			return a.d ~= nil
		end
		return a.i < b.i
	end)
	for i, k in ipairs(keyed) do
		entries[i] = k.e
	end
	return entries
end

-- The point to send the player to for an entry: { map, x, y } nearest on the player's map, else
-- the first point of the zone with the most spawns, else the learned spot. nil for instances.
function Sources.Target(entry, map, px, py)
	if entry.m and entry.x then
		return { map = entry.m, x = entry.x, y = entry.y }
	end
	local best, bestD
	for _, loc in ipairs(entry.locations or {}) do
		if loc.map and loc.points then
			for _, p in ipairs(loc.points) do
				local d = (loc.map == map and px) and ((p[1] - px) ^ 2 + (p[2] - py) ^ 2) or nil
				if not best or (d and (not bestD or d < bestD)) then
					best, bestD = { map = loc.map, x = p[1], y = p[2] }, d
				end
			end
		end
	end
	return best
end

-- Notable drops of an NPC: array of { item, chance }.
function Sources.NpcDrops(npcID)
	local loot = Loot()
	return ns.Codec.ParseDrops(loot and loot.npcDrops[npcID])
end

-- Item IDs whose English name contains every word of the query (case-insensitive), best first:
-- exact name, then prefix, then shorter names. At most `limit`.
function Sources.Search(query, limit)
	local loot = Loot()
	local out = {}
	if not (loot and loot.names and query) then
		return out
	end
	local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
	if q == "" then
		return out
	end
	local words = {}
	for w in q:gmatch("%S+") do
		words[#words + 1] = w
	end
	for id, name in pairs(loot.names) do
		local lower = name:lower()
		local all = true
		for _, w in ipairs(words) do
			if not lower:find(w, 1, true) then
				all = false
				break
			end
		end
		if all then
			local score = (lower == q and 0) or (lower:sub(1, #q) == q and 1) or 2
			out[#out + 1] = { id = id, name = name, score = score }
		end
	end
	table.sort(out, function(a, b)
		if a.score ~= b.score then
			return a.score < b.score
		end
		if #a.name ~= #b.name then
			return #a.name < #b.name
		end
		return a.id < b.id
	end)
	local ids = {}
	for i = 1, math.min(#out, limit or 50) do
		ids[i] = out[i].id
	end
	return ids
end
