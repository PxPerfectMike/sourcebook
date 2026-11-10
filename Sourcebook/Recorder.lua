-- Sourcebook: records what you loot from what, into SourcebookDB.learned (see Learned.lua).
-- A corpse looted a second time in a session is counted as skinning/gathering it. Spawn GUIDs are
-- only stable within a session, so they are never saved.

local _, ns = ...

local Recorder = {}
ns.Recorder = Recorder

local seen = {} -- guid -> "d" after the corpse loot, "k" after skinning, "o" for objects

local function Readable(v)
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return v
end

local function Where()
	local map, x, y = ns.Waypoint.PlayerPosition()
	if not map then
		return nil
	end
	return { m = map, x = x, y = y }
end

local function SourceName(guid)
	for _, unit in ipairs({ "target", "mouseover" }) do
		local good, g = pcall(UnitGUID, unit)
		if good and Readable(g) == guid then
			local good2, name = pcall(UnitName, unit)
			return good2 and Readable(name) or nil
		end
	end
	return nil
end

local handled = false -- LOOT_READY can fire more than once for one loot window

function Recorder.OnLootClosed()
	handled = false
end

function Recorder.OnLootReady()
	local db = ns.db
	if handled or not (db and db.settings.record) then
		return
	end
	handled = true
	local bySource, order = {}, {}
	local all = {}
	for slot = 1, GetNumLootItems() do
		local link = GetLootSlotLink(slot)
		local itemID = link and tonumber(link:match("item:(%d+)"))
		if itemID then
			all[itemID] = true
		end
		local info = { pcall(GetLootSourceInfo, slot) }
		if info[1] then
			for i = 2, #info, 2 do
				local guid = Readable(info[i])
				if type(guid) == "string" then
					if not bySource[guid] then
						bySource[guid] = {}
						order[#order + 1] = guid
					end
					if itemID then
						bySource[guid][itemID] = true
					end
				end
			end
		end
	end
	local where = Where()
	if IsFishingLoot and IsFishingLoot() then
		if where and next(all) then
			ns.Learned.Record(db.learned, "f", where.m, nil, all, where)
			ns.Tooltip.Invalidate()
		end
		return
	end
	for _, guid in ipairs(order) do
		local kind, id = ns.Learned.ParseGUID(guid)
		local prev = seen[guid]
		local items = bySource[guid]
		local record
		if kind == "creature" then
			if not prev then
				record = "d"
			elseif prev.kind == "d" then
				-- Reopening a corpse shows its leftovers again; only new items mean it was skinned
				-- (or mined, or herbed).
				local fresh = {}
				for itemID in pairs(items) do
					if not prev.items[itemID] then
						fresh[itemID] = true
					end
				end
				if next(fresh) then
					record, items = "k", fresh
				end
			end
		elseif kind == "object" and not prev then
			record = "o"
		end
		if record then
			seen[guid] = { kind = record, items = items }
			ns.Learned.Record(db.learned, record, id, SourceName(guid), items, where)
		end
	end
	if #order > 0 then
		ns.Tooltip.Invalidate()
	end
end

-- Forget which corpses were looted (tests, or /sb reset).
function Recorder.Reset()
	seen = {}
end
