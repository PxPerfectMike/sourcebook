-- Sourcebook: loot you have seen yourself. Fills the gaps in the shipped data (Forever's new zones,
-- changed loot tables) and turns into an observed drop rate once a source has been looted enough.
--
-- db (SourcebookDB.learned) = {
--   src  = { ["d6"] = { n = "Kobold Vermin", k = 12, m = 1429, x = 49.1, y = 36.2 }, ... },
--          key = kind .. id; k = times looted; m/x/y = where it was last looted.
--   item = { [2589] = { ["d6"] = 3, ... }, ... },   how many of those loots had the item.
-- }
-- kind: d = creature corpse, k = skinned/gathered corpse, o = object, f = fishing (id = uiMapID).

local _, ns = ...

local Learned = {}
ns.Learned = Learned

Learned.MIN_LOOTS_FOR_RATE = 5

function Learned.Init(db)
	db.src = db.src or {}
	db.item = db.item or {}
	return db
end

-- One opened loot window. items = { [itemID] = true, ... }; where = { m, x, y } or nil.
function Learned.Record(db, kind, id, name, items, where)
	if not (kind and id) then
		return
	end
	local key = kind .. id
	local src = db.src[key]
	if not src then
		src = { k = 0 }
		db.src[key] = src
	end
	src.k = src.k + 1
	if name and name ~= "" then
		src.n = name
	end
	if where and where.m then
		src.m, src.x, src.y = where.m, where.x, where.y
	end
	for itemID in pairs(items) do
		local per = db.item[itemID]
		if not per then
			per = {}
			db.item[itemID] = per
		end
		per[key] = (per[key] or 0) + 1
	end
end

-- Everything you have looted itemID from: array of
-- { kind, id, name, hits, loots, rate (nil until MIN_LOOTS_FOR_RATE loots), m, x, y },
-- most hits first.
function Learned.ForItem(db, itemID)
	local out = {}
	local per = db and db.item and db.item[itemID]
	if not per then
		return out
	end
	for key, hits in pairs(per) do
		local kind, id = key:match("^(%a)(%d+)$")
		local src = db.src[key] or { k = hits }
		local loots = math.max(src.k or 0, hits)
		out[#out + 1] = {
			kind = kind,
			id = tonumber(id),
			name = src.n,
			hits = hits,
			loots = loots,
			rate = loots >= Learned.MIN_LOOTS_FOR_RATE and hits / loots or nil,
			m = src.m,
			x = src.x,
			y = src.y,
		}
	end
	table.sort(out, function(a, b)
		if a.hits ~= b.hits then
			return a.hits > b.hits
		end
		return a.kind .. a.id < b.kind .. b.id
	end)
	return out
end

-- Parses a unit or object GUID: returns "creature" or "object", the NPC/object ID.
-- Format: Type-0-server-instance-zone-ID-spawn (the spawn part is obfuscated per session).
function Learned.ParseGUID(guid)
	if type(guid) ~= "string" then
		return nil
	end
	local kind, id = guid:match("^(%a+)%-%d+%-%w+%-%w+%-%w+%-(%d+)%-")
	if kind == "Creature" or kind == "Vehicle" then
		return "creature", tonumber(id)
	elseif kind == "GameObject" then
		return "object", tonumber(id)
	end
	return nil
end
