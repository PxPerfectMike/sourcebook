-- Sourcebook: decodes the generated data strings. Formats are described at the top of
-- Sourcebook_Loot/Loot.lua and Sourcebook/Data/Recipes.lua.

local _, ns = ...

local Codec = {}
ns.Codec = Codec

local function Split(s, sep)
	local out = {}
	local start = 1
	while true do
		local i = s:find(sep, start, true)
		if not i then
			out[#out + 1] = s:sub(start)
			return out
		end
		out[#out + 1] = s:sub(start, i - 1)
		start = i + 1
	end
end
Codec.Split = Split

-- "d6:1189;k113:3929:1:2;v66:10000:l;#d638" -> list of sources, totals by kind.
function Codec.ParseSources(s)
	local list, totals = {}, {}
	if not s or s == "" then
		return list, totals
	end
	for _, part in ipairs(Split(s, ";")) do
		local totalKind, n = part:match("^#(%a)(%d+)$")
		if totalKind then
			totals[totalKind] = tonumber(n)
		else
			local f = Split(part, ":")
			local kind, id = f[1]:match("^(%a)(%d+)$")
			if kind then
				local e = { kind = kind, id = tonumber(id), chance = (tonumber(f[2]) or 0) / 10000, min = 1, max = 1,
					quest = false, limited = false }
				local i = 3
				if tonumber(f[3]) and tonumber(f[4]) then
					e.min, e.max = tonumber(f[3]), tonumber(f[4])
					i = 5
				end
				for j = i, #f do
					if f[j] == "q" then
						e.quest = true
					elseif f[j] == "l" then
						e.limited = true
					end
				end
				list[#list + 1] = e
			end
		end
	end
	return list, totals
end

-- "i36:2,1436:5:40:78.5:42.9:80.4" -> { { instance = 36, count = 2 }, { map = 1436, count = 5, points = { {40, 78.5}, {42.9, 80.4} } } }
function Codec.ParseLocations(s)
	local out = {}
	if not s or s == "" then
		return out
	end
	for _, part in ipairs(Split(s, ",")) do
		local inst, n = part:match("^i(%d+):(%d+)$")
		if inst then
			out[#out + 1] = { instance = tonumber(inst), count = tonumber(n) }
		else
			local f = Split(part, ":")
			local loc = { map = tonumber(f[1]), count = tonumber(f[2]) or 0, points = {} }
			for j = 3, #f - 1, 2 do
				local x, y = tonumber(f[j]), tonumber(f[j + 1])
				if x and y then
					loc.points[#loc.points + 1] = { x, y }
				end
			end
			if loc.map then
				out[#out + 1] = loc
			end
		end
	end
	return out
end

-- "name|level or min-max|rank|locations"
function Codec.ParseNpc(s)
	if not s then
		return nil
	end
	local f = Split(s, "|")
	local lo, hi = (f[2] or ""):match("^(%d+)%-(%d+)$")
	lo = tonumber(lo or f[2])
	hi = tonumber(hi) or lo
	return { name = f[1], levelMin = lo, levelMax = hi, rank = tonumber(f[3]) or 0, locations = Codec.ParseLocations(f[4]) }
end

-- "name|kind|locations"
function Codec.ParseObject(s)
	if not s then
		return nil
	end
	local f = Split(s, "|")
	return { name = f[1], kind = f[2] or "O", locations = Codec.ParseLocations(f[3]) }
end

-- "itemID:chance;..."
function Codec.ParseDrops(s)
	local out = {}
	if not s or s == "" then
		return out
	end
	for _, part in ipairs(Split(s, ";")) do
		local item, chance = part:match("^(%d+):(%d+)$")
		if item then
			out[#out + 1] = { item = tonumber(item), chance = tonumber(chance) / 10000 }
		end
	end
	return out
end

-- ns.Recipes[spellID] as a table.
function Codec.Recipe(spellID)
	local t = ns.Recipes and ns.Recipes[spellID]
	if not t then
		return nil
	end
	local r = { spell = spellID, skill = t[1], item = t[2], count = t[3], orange = t[4], yellow = t[5], gray = t[6],
		learnedFrom = t[7], reagents = {} }
	for i = 8, #t - 1, 2 do
		r.reagents[#r.reagents + 1] = { item = t[i], count = t[i + 1] }
	end
	return r
end
