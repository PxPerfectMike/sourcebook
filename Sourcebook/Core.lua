-- Sourcebook: startup, saved settings, slash commands, and the game-name lookups Format uses.

local ADDON, ns = ...

ns.Loot = SourcebookLoot

local DEFAULTS = {
	book = true, -- the illustrated book (false: the plain window)
	tooltip = true, -- sources and crafting lines on item tooltips
	mobTooltip = true, -- notable drops on creature tooltips
	record = true, -- remember what you loot from what
}

local function Say(msg)
	print("|cff88ccffSourcebook|r: " .. msg)
end

-- Does the player know this recipe spell?
function ns.Knows(spellID)
	if IsPlayerSpell then
		local good, known = pcall(IsPlayerSpell, spellID)
		if good and known then
			return true
		end
	end
	if IsSpellKnown then
		local good, known = pcall(IsSpellKnown, spellID)
		return good and known or false
	end
	return false
end

local function WireNames()
	local names = ns.Format.names
	local fallbackItem = names.item
	local zoneCache, instanceCache, areaCache = {}, {}, {}
	names.zone = function(map)
		if zoneCache[map] == nil then
			local info = C_Map.GetMapInfo(map)
			zoneCache[map] = info and info.name or ("Map " .. map)
		end
		return zoneCache[map]
	end
	names.instance = function(mapID)
		if instanceCache[mapID] == nil then
			local good, name = pcall(GetRealZoneText, mapID)
			instanceCache[mapID] = (good and name and name ~= "") and name or ("Instance " .. mapID)
		end
		return instanceCache[mapID]
	end
	names.area = function(areaID)
		if areaCache[areaID] == nil then
			local good, name = pcall(C_Map.GetAreaInfo, areaID)
			areaCache[areaID] = (good and name and name ~= "") and name or ("Area " .. areaID)
		end
		return areaCache[areaID]
	end
	names.item = function(itemID)
		local name = C_Item.GetItemNameByID(itemID)
		if name then
			return name
		end
		C_Item.RequestLoadItemDataByID(itemID)
		return fallbackItem(itemID)
	end
	names.spell = function(spellID)
		local good, name = pcall(C_Spell.GetSpellName, spellID)
		return (good and name) or ("Spell " .. spellID)
	end
	local fallbackProfession = names.profession
	names.profession = function(skillLine)
		if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName then
			local good, name = pcall(C_TradeSkillUI.GetTradeSkillDisplayName, skillLine)
			if good and name and name ~= "" then
				return name
			end
		end
		return fallbackProfession(skillLine)
	end
end

-- Every way in goes through here: the book when it's on and its art loaded, else the plain
-- window. A Lua error inside the book also falls back, so a lookup always opens something.
local function UseBook()
	return ns.db and ns.db.settings.book and ns.BookArt and ns.Book and ns.BookPages
end

local function Route(bookFn, panelFn, ...)
	if UseBook() then
		local good, err = pcall(bookFn, ...)
		if good then
			return
		end
		geterrorhandler()(err)
	end
	panelFn(...)
end

function ns.ShowItem(id)
	Route(ns.BookPages and ns.BookPages.ShowItem, ns.Panel.ShowItem, id)
end

function ns.ShowRecipe(spell)
	Route(ns.BookPages and ns.BookPages.ShowRecipe, ns.Panel.ShowRecipe, spell)
end

function ns.ShowSearch(text)
	Route(ns.BookPages and ns.BookPages.ShowSearch, ns.Panel.ShowSearch, text)
end

function ns.Toggle()
	Route(ns.BookPages and ns.BookPages.Toggle, ns.Panel.Toggle)
end

local function ItemFromText(text)
	local id = text:match("item:(%d+)") or text:match("^%s*(%d+)%s*$")
	return tonumber(id)
end

local function Toggle(key, arg, label)
	local db = ns.db.settings
	if arg == "on" then
		db[key] = true
	elseif arg == "off" then
		db[key] = false
	else
		db[key] = not db[key]
	end
	Say(label .. " " .. (db[key] and "on" or "off") .. ".")
end

local function Slash(msg)
	msg = msg or ""
	local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	if cmd == "tooltip" then
		Toggle("tooltip", rest, "Item tooltip lines")
	elseif cmd == "mobs" then
		Toggle("mobTooltip", rest, "Creature tooltip drops")
	elseif cmd == "record" then
		Toggle("record", rest, "Loot recording")
	elseif cmd == "classic" then
		ns.Panel.Toggle()
	elseif cmd == "book" then
		Toggle("book", rest, "The illustrated book")
	elseif cmd == "forget" then
		ns.db.learned = ns.Learned.Init({})
		ns.Recorder.Reset()
		ns.Tooltip.Invalidate()
		Say("forgot everything you looted.")
	elseif cmd == "help" then
		Say("/sb [item name, link or ID] - look it up.  /sb - open the search.")
		Say("/sb tooltip | mobs | record | book [on|off] - item tooltip lines, creature drops, loot recording, the illustrated book.")
		Say("/sb classic - the plain window.")
		Say("/sb forget - clear what you have looted.")
		Say("To open an item: Ctrl+Shift-click it in your bags, Alt-click its link in chat, or bind a key under Options > Keybindings > AddOns > Sourcebook (\"Look up the hovered item\") and press it while hovering any item, bags included.")
	elseif msg:match("^%s*$") then
		ns.Toggle()
	else
		local id = ItemFromText(msg)
		if id then
			ns.ShowItem(id)
		else
			ns.ShowSearch(msg:match("^%s*(.-)%s*$"))
		end
	end
end

-- Key binding (Bindings.xml): look up the item under the mouse.
function Sourcebook_LookupHovered()
	local id = ns.Tooltip.HoveredItem()
	if id then
		ns.ShowItem(id)
	else
		ns.Toggle()
	end
end
BINDING_HEADER_SOURCEBOOK = "Sourcebook"
BINDING_NAME_SOURCEBOOK_LOOKUP = "Look up the hovered item"

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		SourcebookDB = SourcebookDB or {}
		local db = SourcebookDB
		db.settings = db.settings or {}
		for k, v in pairs(DEFAULTS) do
			if db.settings[k] == nil then
				db.settings[k] = v
			end
		end
		db.learned = ns.Learned.Init(db.learned or {})
		db.recent = db.recent or {}
		ns.db = db
		ns.Loot = ns.Loot or SourcebookLoot
		if not ns.Loot then
			Say("the Sourcebook_Loot data addon is missing or disabled; only recipes and your own loot will show.")
			ns.Loot = { item = {}, npc = {}, obj = {}, npcDrops = {}, names = {} }
		end
		WireNames()
		ns.Tooltip.Hook()
		hooksecurefunc("SetItemRef", function(link)
			if IsAltKeyDown() and type(link) == "string" then
				local id = link:match("^item:(%d+)")
				if id then
					ns.ShowItem(tonumber(id))
				end
			end
		end)
		-- Ctrl+Shift-click an item in your bags (or anywhere the game handles modified item clicks).
		-- Ctrl is also "dressing room", so close the dressing room again if the click opened it.
		local dressUpWasShown = false
		hooksecurefunc("HandleModifiedItemClick", function(link)
			if not (IsControlKeyDown() and IsShiftKeyDown()) or type(link) ~= "string" then
				return
			end
			local id = link:match("item:(%d+)")
			if not id then
				return
			end
			ns.ShowItem(tonumber(id))
			if DressUpFrame and DressUpFrame:IsShown() and not dressUpWasShown then
				HideUIPanel(DressUpFrame)
			end
		end)
		pcall(events.RegisterEvent, events, "GLOBAL_MOUSE_DOWN")
		events.beforeClick = function()
			dressUpWasShown = DressUpFrame and DressUpFrame:IsShown() or false
		end
		SLASH_SOURCEBOOK1 = "/sourcebook"
		SLASH_SOURCEBOOK2 = "/sb"
		SlashCmdList.SOURCEBOOK = Slash
		events:RegisterEvent("LOOT_READY")
		events:RegisterEvent("LOOT_CLOSED")
		events:RegisterEvent("MODIFIER_STATE_CHANGED")
		events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
		events:RegisterEvent("BAG_UPDATE_DELAYED")
	elseif event == "GLOBAL_MOUSE_DOWN" then
		events.beforeClick() -- fires before the click handlers, so this is the pre-click state
	elseif event == "LOOT_READY" then
		ns.Recorder.OnLootReady()
	elseif event == "LOOT_CLOSED" then
		ns.Recorder.OnLootClosed()
	elseif event == "MODIFIER_STATE_CHANGED" then
		if arg1 == "LSHIFT" or arg1 == "RSHIFT" then
			ns.Tooltip.OnModifier()
		end
	elseif event == "GET_ITEM_INFO_RECEIVED" or event == "BAG_UPDATE_DELAYED" then
		ns.Panel.OnItemInfo()
		if ns.BookPages and ns.BookPages.OnItemInfo then
			ns.BookPages.OnItemInfo()
		end
	end
end)
