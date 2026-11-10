-- Sourcebook: text for tooltips and the panel. Pure; the game-name lookups are plugged in by
-- Core.lua (and by the tests) through Format.names.

local _, ns = ...

local Format = {}
ns.Format = Format

Format.names = {
	zone = function(uiMapID)
		return "Map " .. uiMapID
	end,
	instance = function(mapID)
		return "Instance " .. mapID
	end,
	area = function(areaID)
		return "Area " .. areaID
	end,
	item = function(itemID)
		local loot = ns.Loot or SourcebookLoot
		return loot and loot.names and loot.names[itemID] or ("Item " .. itemID)
	end,
	spell = function(spellID)
		return "Spell " .. spellID
	end,
	profession = function(skillLine)
		return ns.Professions and ns.Professions[skillLine] or ("Skill " .. skillLine)
	end,
}

local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local GRAY = { 0.6, 0.6, 0.6 }
local GREEN = { 0.4, 0.9, 0.4 }
local BLUE = { 0.53, 0.8, 1 }

function Format.Chance(p)
	if not p then
		return ""
	end
	local pct = p * 100
	if pct >= 99.5 then
		return "100%"
	elseif pct >= 10 then
		return string.format("%d%%", math.floor(pct + 0.5))
	elseif pct >= 1 then
		return (string.format("%.1f%%", pct):gsub("%.0%%", "%%"))
	elseif pct >= 0.1 then
		return string.format("%.1f%%", pct)
	end
	return "<0.1%"
end

function Format.Levels(lo, hi)
	if not lo then
		return ""
	end
	if lo == hi or not hi then
		return tostring(lo)
	end
	return lo .. "-" .. hi
end

local RANK = { [1] = "Elite", [2] = "Rare Elite", [3] = "Boss", [4] = "Rare" }
function Format.Rank(rank)
	return RANK[rank]
end

-- Where an entry is, in a few words: "Westfall", "Westfall, Duskwood +3", "The Deadmines".
function Format.Where(entry, maxZones)
	maxZones = maxZones or 2
	if entry.m then
		return Format.names.zone(entry.m)
	end
	local locs = entry.locations
	if not locs or #locs == 0 then
		return nil
	end
	local parts = {}
	for i = 1, math.min(#locs, maxZones) do
		local loc = locs[i]
		parts[#parts + 1] = loc.instance and Format.names.instance(loc.instance) or Format.names.zone(loc.map)
	end
	local text = table.concat(parts, ", ")
	if #locs > maxZones then
		text = text .. " +" .. (#locs - maxZones)
	end
	return text
end

-- One source as a short phrase.
function Format.Entry(group, e)
	local key = group.key
	if key == "c" then
		return Format.names.item(e.id), Format.Chance(e.chance)
	elseif key == "f" then
		return Format.names.area(e.id), Format.Chance(e.chance)
	elseif key == "learned" then
		local name = e.name or (e.kind .. e.id)
		local where = e.m and Format.names.zone(e.m)
		local stat = e.rate and Format.Chance(e.rate) or (e.hits .. "/" .. e.loots)
		return name .. (where and (" (" .. where .. ")") or ""), stat
	end
	local name = e.name or ("#" .. e.id)
	local bits = {}
	if e.levelMin and key ~= "v" then
		bits[#bits + 1] = Format.Levels(e.levelMin, e.levelMax)
	end
	local rank = Format.Rank(e.rank)
	if rank and key ~= "v" then
		bits[#bits + 1] = rank
	end
	local where = Format.Where(e, key == "v" and 1 or 2)
	if where then
		bits[#bits + 1] = where
	end
	local text = name
	if #bits > 0 then
		text = text .. " (" .. table.concat(bits, ", ") .. ")"
	end
	local stat
	if key == "v" then
		stat = e.limited and "limited" or ""
	else
		stat = Format.Chance(e.chance)
		if e.max and e.max > 1 then
			stat = (e.min == e.max and e.max or (e.min .. "-" .. e.max)) .. "x " .. stat
		end
		if e.quest then
			stat = stat .. " (quest)"
		end
	end
	if e.seen then
		local s = e.seen
		stat = stat .. "  you: " .. (s.rate and Format.Chance(s.rate) or (s.hits .. "/" .. s.loots))
	end
	return text, stat
end

-- Tooltip lines for an item: array of { left, right, color }. opts.full shows more per group.
-- info is Sources.ForItem's result; craft = { createdBy, usedIn, teaches } from Craft.
function Format.ItemLines(info, craft, opts)
	opts = opts or {}
	local perGroup = opts.full and 6 or 2
	local lines = {}
	local function add(left, right, color)
		lines[#lines + 1] = { left = left, right = right or "", color = color or WHITE }
	end
	for _, group in ipairs(info.groups) do
		add(group.label .. ":", nil, GOLD)
		local n = math.min(#group.entries, perGroup)
		for i = 1, n do
			local text, stat = Format.Entry(group, group.entries[i])
			add("  " .. text, stat)
		end
		local more = group.total - n
		if more > 0 then
			local noun = (group.key == "v" and "vendors") or (group.key == "c" and "containers") or
				(group.key == "f" and "areas") or "more"
			add("  +" .. more .. " " .. noun, nil, GRAY)
		end
	end
	if craft then
		if craft.teaches then
			local r = craft.teaches
			local known = opts.knows and opts.knows(r.spell)
			add("Teaches: " .. Format.names.spell(r.spell),
				Format.names.profession(r.skill) .. " " .. r.orange, known and GREEN or BLUE)
			if known then
				add("  You know this recipe", nil, GREEN)
			end
		end
		for i, r in ipairs(craft.createdBy or {}) do
			if i > (opts.full and 4 or 2) then
				add("  +" .. (#craft.createdBy - i + 1) .. " more recipes", nil, GRAY)
				break
			end
			add("Crafted: " .. Format.names.spell(r.spell), Format.names.profession(r.skill) .. " " .. r.orange, BLUE)
		end
		local usedIn = craft.usedIn or {}
		if #usedIn > 0 then
			local bySkill, order = {}, {}
			for _, r in ipairs(usedIn) do
				if not bySkill[r.skill] then
					bySkill[r.skill] = 0
					order[#order + 1] = r.skill
				end
				bySkill[r.skill] = bySkill[r.skill] + 1
			end
			local parts = {}
			for _, skill in ipairs(order) do
				parts[#parts + 1] = Format.names.profession(skill) .. " " .. bySkill[skill]
			end
			add("Reagent for " .. #usedIn .. (#usedIn == 1 and " recipe" or " recipes"), nil, BLUE)
			add("  " .. table.concat(parts, ", "), nil, GRAY)
		end
	end
	return lines
end

-- Notable drops of an NPC as tooltip lines.
function Format.NpcLines(drops, max)
	local lines = {}
	for i = 1, math.min(#drops, max or 3) do
		local d = drops[i]
		lines[#lines + 1] = { left = "  " .. Format.names.item(d.item), right = Format.Chance(d.chance), color = WHITE }
	end
	return lines
end
