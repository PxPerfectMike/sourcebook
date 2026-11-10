-- Sourcebook: lines on item tooltips (where it comes from, what it crafts) and on creature
-- tooltips (the notable things it drops). Hold Shift for more lines.

local _, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

local cache = {} -- itemID -> { info, craft } (cleared when you loot something)

function Tooltip.Invalidate()
	cache = {}
end

function Tooltip.Gather(itemID)
	local c = cache[itemID]
	if not c then
		c = {
			info = ns.Sources.ForItem(itemID, ns.db and ns.db.learned),
			craft = {
				createdBy = ns.Craft.CreatedBy(itemID),
				usedIn = ns.Craft.UsedIn(itemID),
				teaches = ns.Craft.Teaches(itemID),
			},
		}
		cache[itemID] = c
	end
	return c
end

local function Readable(v)
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return v
end

local function AddLines(tooltip, lines)
	for _, l in ipairs(lines) do
		local c = l.color
		if l.right ~= "" then
			tooltip:AddDoubleLine(l.left, l.right, c[1], c[2], c[3], 1, 1, 1)
		else
			tooltip:AddLine(l.left, c[1], c[2], c[3])
		end
	end
end

local function ItemIDFrom(tooltip, data)
	local id = data and Readable(data.id)
	if type(id) == "number" then
		return id
	end
	local good, _, link = pcall(tooltip.GetItem, tooltip)
	link = good and Readable(link)
	return link and tonumber(link:match("item:(%d+)"))
end

local function OnItem(tooltip, data)
	if not (ns.db and ns.db.settings.tooltip) then
		return
	end
	if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then
		return -- not the comparison tooltips
	end
	local itemID = ItemIDFrom(tooltip, data)
	if not itemID then
		return
	end
	local c = Tooltip.Gather(itemID)
	for _, group in ipairs(c.info.groups) do
		if group.key == "v" then
			local map, px, py = ns.Waypoint.PlayerPosition()
			ns.Sources.SortByDistance(group.entries, map, px, py)
		end
	end
	local lines = ns.Format.ItemLines(c.info, c.craft, {
		full = IsShiftKeyDown(),
		knows = ns.Knows,
	})
	if #lines == 0 then
		return
	end
	tooltip:AddLine(" ")
	AddLines(tooltip, lines)
	if not IsShiftKeyDown() then
		tooltip:AddLine(Tooltip.Hint(tooltip == ItemRefTooltip), 0.45, 0.45, 0.45)
	end
end

local function OnUnit(tooltip)
	if not (ns.db and ns.db.settings.mobTooltip) then
		return
	end
	local good, _, unit = pcall(tooltip.GetUnit, tooltip)
	if not good or not unit then
		return
	end
	local good2, guid = pcall(UnitGUID, unit)
	guid = good2 and Readable(guid)
	local kind, id = ns.Learned.ParseGUID(guid)
	if kind ~= "creature" then
		return
	end
	local drops = ns.Sources.NpcDrops(id)
	if #drops == 0 then
		return
	end
	tooltip:AddLine("Notable drops:", 1, 0.82, 0)
	AddLines(tooltip, ns.Format.NpcLines(drops, IsShiftKeyDown() and 8 or 3))
end

function Tooltip.Hook()
	if not (TooltipDataProcessor and Enum and Enum.TooltipDataType) then
		return
	end
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
		pcall(OnItem, tooltip, data)
	end)
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
		pcall(OnUnit, tooltip)
	end)
end

-- Redraw the hovered tooltip when Shift goes down or up.
function Tooltip.OnModifier()
	if GameTooltip:IsShown() and GameTooltip.RefreshData then
		pcall(GameTooltip.RefreshData, GameTooltip)
	end
end

-- The hint under the lines. Alt-click only works on chat links (bag addons such as Baganator
-- use Alt-click themselves), so in bags the hint names the key binding, if one is set.
function Tooltip.Hint(fromChatLink)
	if fromChatLink then
		return "Shift: more   Alt-click the link: open in Sourcebook"
	end
	local key = GetBindingKey and GetBindingKey("SOURCEBOOK_LOOKUP")
	if key then
		local name = GetBindingText and GetBindingText(key) or key
		return "Shift: more   Ctrl+Shift-click or " .. name .. ": open in Sourcebook"
	end
	return "Shift: more   Ctrl+Shift-click: open in Sourcebook"
end

-- The item under the mouse, for the key binding.
function Tooltip.HoveredItem()
	if not GameTooltip:IsShown() then
		return nil
	end
	return ItemIDFrom(GameTooltip, nil)
end
