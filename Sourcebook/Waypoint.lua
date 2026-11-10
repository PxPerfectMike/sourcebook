-- Sourcebook: send the player somewhere. TomTom's arrow when it is installed, else the game's own
-- map pin with the super-tracking arrow.

local _, ns = ...

local Waypoint = {}
ns.Waypoint = Waypoint

-- Returns true when a waypoint was set. x, y in map percent.
function Waypoint.Set(map, x, y, title)
	if not (map and x and y) then
		return false
	end
	if TomTom and TomTom.AddWaypoint then
		local good = pcall(TomTom.AddWaypoint, TomTom, map, x / 100, y / 100, {
			title = title,
			from = "Sourcebook",
			persistent = false,
			crazy = true,
		})
		if good then
			return true
		end
	end
	if C_Map and C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(map) then
		local point = UiMapPoint.CreateFromCoordinates(map, x / 100, y / 100)
		C_Map.SetUserWaypoint(point)
		if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
			C_SuperTrack.SetSuperTrackedUserWaypoint(true)
		end
		return true
	end
	return false
end

-- The player's map and position in percent, or nil (inside instances the game may refuse).
function Waypoint.PlayerPosition()
	local good, map = pcall(C_Map.GetBestMapForUnit, "player")
	if not good or not map then
		return nil
	end
	local good2, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
	if not good2 or not pos then
		return map
	end
	local x, y = pos:GetXY()
	if issecretvalue and (issecretvalue(x) or issecretvalue(y)) then
		return map
	end
	return map, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
end

-- Waypoint to the best point of a source entry. Returns true on success.
function Waypoint.ToEntry(entry)
	local map, px, py = Waypoint.PlayerPosition()
	local target = ns.Sources.Target(entry, map, px, py)
	if not target then
		return false
	end
	local ok = Waypoint.Set(target.map, target.x, target.y, entry.name)
	if ok then
		print(string.format("|cff88ccffSourcebook|r: waypoint to %s, %s %.1f, %.1f", entry.name or "?",
			ns.Format.names.zone(target.map), target.x, target.y))
	end
	return ok
end
