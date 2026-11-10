-- Loads every Sourcebook file the way the game does, against a stubbed WoW API, then logs in and
-- drives the tooltips, the panel's three views, the slash commands and two loot windows.
-- It catches nil calls and typos in the game-facing files; it can't tell whether the real API
-- behaves the way the stubs do.

local function Any(name)
	return setmetatable({}, {
		__index = function(_, k)
			if type(k) ~= "string" or not k:match("^%u") then
				return nil -- only methods (capitalized) exist on a frame; addon fields start empty
			end
			return function(...)
				-- Strings measure by length, so layout code that fits text can be tested.
				if k == "SetText" then
					local self, text = ...
					rawset(self, "_text", text)
					return
				end
				if k == "GetStringWidth" then
					local self = ...
					return #(tostring(rawget(self, "_text") or "")) * 7
				end
				if k == "SetAlphaGradient" then
					-- The client rejects a zero or negative length ("length must be greater than 0").
					local _, start, length = ...
					assert(type(start) == "number" and start >= 0, "SetAlphaGradient: bad start")
					assert(type(length) == "number" and length > 0, "SetAlphaGradient(): length must be greater than 0")
					return false
				end
				if k == "IsShown" then
					return true
				end
				if k == "GetText" then
					return ""
				end
				if k == "GetWidth" or k == "GetHeight" or k == "GetStringHeight" or k == "GetStringWidth"
					or k == "GetLineHeight" or k == "GetAlpha" then
					return k == "GetAlpha" and 1 or 40
				end
				if k == "GetSize" then
					return 400, 560
				end
				if k == "GetFrameLevel" or k == "GetScale" then
					return 1
				end
				if k == "GetCenter" or k == "GetLeft" or k == "GetTop" then
					return 100, 100
				end
				if k == "GetFont" then
					return "Fonts\FRIZQT__.TTF", 12, ""
				end
				if k == "CreateTexture" or k == "CreateFontString" or k == "CreateMaskTexture" then
					return Any(name .. "." .. k)
				end
				return nil
			end
		end,
	})
end

local frames = {}
function CreateFrame(kind, name)
	local f = Any("Frame")
	local scripts, events = {}, {}
	rawset(f, "SetScript", function(_, s, fn)
		scripts[s] = fn
	end)
	rawset(f, "GetScript", function(_, s)
		return scripts[s]
	end)
	rawset(f, "RegisterEvent", function(_, e)
		events[e] = true
	end)
	rawset(f, "Fire", function(self, e, ...)
		if events[e] and scripts.OnEvent then
			scripts.OnEvent(self, e, ...)
		end
	end)
	rawset(f, "Click", function(self)
		scripts.OnClick(self)
	end)
	frames[#frames + 1] = f
	if name then
		_G[name] = f
	end
	return f
end

UIParent = Any("UIParent")
rawset(UIParent, "GetHeight", function()
	return 768
end)
rawset(UIParent, "GetWidth", function()
	return 1366
end)
UISpecialFrames = {}
tinsert = table.insert
unpack = unpack or table.unpack
Enum = { TooltipDataType = { Item = 0, Unit = 2 } }
local postCalls = {}
TooltipDataProcessor = {
	AddTooltipPostCall = function(kind, fn)
		postCalls[kind] = fn
	end,
}
local tipLines = {}
local function Tip()
	local t = Any("Tooltip")
	rawset(t, "AddLine", function(_, text)
		tipLines[#tipLines + 1] = text
	end)
	rawset(t, "AddDoubleLine", function(_, l, r)
		tipLines[#tipLines + 1] = l .. " | " .. r
	end)
	return t
end
GameTooltip = Tip()
ItemRefTooltip = Tip()
rawset(GameTooltip, "GetUnit", function()
	return "Kobold Vermin", "mouseover"
end)
rawset(GameTooltip, "GetItem", function()
	return "Linen Cloth", "|cffffffff|Hitem:2589::::::::|h[Linen Cloth]|h|r"
end)

local timers = {}
C_Timer = {
	After = function(_, fn)
		timers[#timers + 1] = fn
	end,
	NewTimer = function(_, fn)
		timers[#timers + 1] = fn
		return { Cancel = function() end }
	end,
}
function CreateFont(name)
	local f = Any("Font")
	_G[name] = f
	return f
end
function PlaySound() end
function CreateColor(r, g, b, a)
	return { r = r, g = g, b = b, a = a }
end
inCombat = false
function InCombatLockdown()
	return inCombat
end
SOUNDKIT = {}
function geterrorhandler()
	return function(err)
		error(err, 0)
	end
end
function BreakUpLargeNumbers(n)
	return tostring(n)
end
function hooksecurefunc(name, fn)
	local old = _G[name] or function() end
	_G[name] = function(...)
		old(...)
		fn(...)
	end
end
function SetItemRef() end
local shift, alt = false, false
function IsShiftKeyDown()
	return shift
end
function IsAltKeyDown()
	return alt
end
ctrl = false
function IsControlKeyDown()
	return ctrl
end
function HandleModifiedItemClick() end
function GetCursorPosition()
	return 0, 0
end
issecretvalue = function()
	return false
end
SlashCmdList = {}

local printed = {}
function print(...)
	local line = table.concat({ ... }, " ")
	if line:find("^DEBUG") then
		io.write(line, "\n")
	end
	printed[#printed + 1] = table.concat({ ... }, " ")
end

C_Item = {
	GetItemNameByID = function(id)
		return nil
	end,
	RequestLoadItemDataByID = function() end,
	GetItemIconByID = function()
		return 1
	end,
	GetItemCount = function(id)
		return id == 2770 and 3 or 0
	end,
}
C_Spell = {
	GetSpellName = function(id)
		return "Spell" .. id
	end,
	GetSpellTexture = function()
		return 2
	end,
}
local waypoints = {}
UiMapPoint = {
	CreateFromCoordinates = function(m, x, y)
		return { m, x, y }
	end,
}
C_Map = {
	GetMapInfo = function(m)
		return { name = "Zone" .. m }
	end,
	GetAreaInfo = function(a)
		return "Area" .. a
	end,
	GetBestMapForUnit = function()
		return 1429
	end,
	GetPlayerMapPosition = function()
		return {
			GetXY = function()
				return 0.5, 0.4
			end,
		}
	end,
	CanSetUserWaypointOnMap = function()
		return true
	end,
	SetUserWaypoint = function(p)
		waypoints[#waypoints + 1] = p
	end,
}
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
function GetRealZoneText(id)
	return "Instance" .. id
end
function IsPlayerSpell(id)
	return id == 2657
end
function UnitGUID(unit)
	return "Creature-0-1-0-1-6-0000ABCDEF"
end
function UnitName()
	return "Kobold Vermin"
end

local loot = {}
function GetNumLootItems()
	return #loot
end
function GetLootSlotLink(slot)
	return loot[slot].link
end
function GetLootSourceInfo(slot)
	return loot[slot].guid, 1
end
function IsFishingLoot()
	return false
end

-- Load the addon.
local ns = {}
for _, file in ipairs(ADDON_FILES) do
	local fn = assert(loadstring(ADDON_SOURCE[file], "@Sourcebook/" .. file))
	fn("Sourcebook", ns)
end
local events
for _, f in ipairs(frames) do
	if f:GetScript("OnEvent") then
		events = f
	end
end
assert(events, "no event frame")
events:Fire("ADDON_LOADED", "Sourcebook")
assert(ns.db and ns.db.settings.tooltip, "settings not initialized")
assert(postCalls[0] and postCalls[2], "tooltip post calls not registered")

-- Item tooltip: Linen Cloth has drops; Copper Ore is a reagent for Smelt Copper.
postCalls[0](GameTooltip, { id = 2589 })
local text = table.concat(tipLines, "\n")
assert(text:find("Dropped by"), "Linen Cloth tooltip has no drops:\n" .. text)
tipLines = {}
shift = true
postCalls[0](GameTooltip, { id = 2770 })
shift = false
text = table.concat(tipLines, "\n")
assert(text:find("Mined from"), "Copper Ore tooltip has no veins:\n" .. text)
assert(text:find("Reagent for"), "Copper Ore tooltip has no recipes:\n" .. text)
tipLines = {}
postCalls[0](GameTooltip, nil) -- falls back to GetItem
assert(#tipLines > 0, "tooltip without data.id added nothing")

-- Creature tooltip.
tipLines = {}
postCalls[2](GameTooltip)
assert(table.concat(tipLines, "\n"):find("Notable drops"), "Kobold Vermin has no notable drops")

-- Panel: search, an item, a recipe, clicking every row.
local function ClickAll()
	for _, f in ipairs(frames) do
		local onClick = f:GetScript("OnClick")
		local spec = rawget(f, "spec")
		if onClick and spec and spec.onClick then
			onClick(f)
		end
	end
end
-- First thing in a session: open straight onto an item. Back must still have somewhere to go.
ns.ShowItem(2589)
assert(ns.BookPages.Current().kind == "item", "opened onto the item")
ns.BookPages.GoBack()
assert(ns.BookPages.Current().kind == "index", "a fresh open onto an item has the index underneath")
SlashCmdList.SOURCEBOOK("copper ore")
SlashCmdList.SOURCEBOOK("2770")
ClickAll()
ns.Panel.ShowRecipe(2657)
ClickAll()
ns.Panel.ShowItem(2589)
ClickAll()
assert(#waypoints > 0, "no waypoint was set from the item view")
ns.Panel.ShowRecipe(99999999)
SlashCmdList.SOURCEBOOK("")
SlashCmdList.SOURCEBOOK("help")
SlashCmdList.SOURCEBOOK("tooltip off")
assert(ns.db.settings.tooltip == false, "tooltip toggle")
SlashCmdList.SOURCEBOOK("tooltip on")
for _, fn in ipairs(timers) do
	fn()
end
alt = true
SetItemRef("item:2589::::", "[Linen Cloth]")
alt = false
ctrl = true
shift = true
DressUpFrame = { IsShown = function() return true end }
local hidden = false
function HideUIPanel() hidden = true end
events:Fire("GLOBAL_MOUSE_DOWN")
HandleModifiedItemClick("|cffffffff|Hitem:2770::::|h[Copper Ore]|h|r")
assert(not hidden, "closed a dressing room that was already open")
DressUpFrame = { IsShown = function() return false end }
events:Fire("GLOBAL_MOUSE_DOWN")
HandleModifiedItemClick("|cffffffff|Hitem:2770::::|h[Copper Ore]|h|r")
ctrl, shift = false, false

-- Loot: the corpse, then the same corpse again (skinning).
loot = { { link = "|Hitem:2589::|h", guid = "Creature-0-1-0-1-6-0000ABCDEF" } }
events:Fire("LOOT_READY")
events:Fire("LOOT_READY") -- a repeat within one window must not count
events:Fire("LOOT_CLOSED")
events:Fire("LOOT_READY") -- reopening the corpse with the same leftover is not skinning
events:Fire("LOOT_CLOSED")
assert(ns.db.learned.src.k6 == nil, "leftover reopen counted as skinning")
loot = { { link = "|Hitem:2318::|h", guid = "Creature-0-1-0-1-6-0000ABCDEF" } }
events:Fire("LOOT_READY")
events:Fire("LOOT_CLOSED")
local learned = ns.db.learned
assert(learned.src.d6 and learned.src.d6.k == 1, "corpse loot not recorded once")
assert(learned.src.k6 and learned.item[2318].k6 == 1, "second loot not recorded as skinning")

-- A Forever-only creature the shipped data doesn't know shows up as "You looted it from".
loot = { { link = "|Hitem:2589::|h", guid = "Creature-0-1-0-1-999999-0000ABCDEF" } }
events:Fire("LOOT_READY")
events:Fire("LOOT_CLOSED")
tipLines = {}
postCalls[0](GameTooltip, { id = 2589 })
assert(table.concat(tipLines, "\n"):find("You looted it from"), "learned source missing from the tooltip")

SlashCmdList.SOURCEBOOK("forget")
assert(next(ns.db.learned.src) == nil, "forget")

-- The book: open it, let the cover swing, write, search, turn, go back, close.
local function Tick(seconds)
	for _ = 1, math.floor(seconds / 0.05) do
		for _, f in ipairs(frames) do
			local onUpdate = f:GetScript("OnUpdate")
			if onUpdate then
				onUpdate(f, 0.05)
			end
		end
	end
	for _, fn in ipairs(timers) do
		fn()
	end
	timers = {}
end
local function RowsWith(predicate)
	local out = {}
	for _, f in ipairs(frames) do
		local spec = rawget(f, "spec")
		if spec and predicate(spec) and f:GetScript("OnClick") then
			out[#out + 1] = f
		end
	end
	return out
end
assert(ns.db.settings.book, "the book is the default")
assert(ns.Book.IsOpen(), "the earlier /sb lookups should have opened the book")
Tick(3)
ns.Book.Close()
Tick(1)
assert(not ns.Book.IsOpen(), "close")
SlashCmdList.SOURCEBOOK("")
assert(ns.Book.IsOpen(), "book did not start opening")
Tick(3)
assert(not ns.Book.IsBusy(), "book still busy after opening")
-- The book reopens where you left off; go to the index for the search tests.
ns.BookPages.GoIndex()
Tick(1.5)
assert(ns.BookPages.Current().kind == "index", "Index")
-- Type a search: the box is an EditBox on the index's left page.
local box
for _, f in ipairs(frames) do
	if f:GetScript("OnTextChanged") and f:GetScript("OnEnterPressed") then
		box = f
	end
end
assert(box, "no search box on the index")
rawset(box, "GetText", function()
	return "copper"
end)
box:GetScript("OnTextChanged")(box, true)
Tick(1)
-- Click the first item row: the page turns to its entry.
local itemRows = RowsWith(function(spec)
	return spec.item ~= nil and spec.onClick ~= nil
end)
assert(#itemRows > 0, "no item rows on the index")
itemRows[1]:GetScript("OnClick")(itemRows[1])
Tick(2)
assert(not ns.Book.IsBusy(), "turn never finished")
-- Click every clickable row on the entry (waypoints, recipes), letting each turn finish.
for _, r in ipairs(RowsWith(function(spec)
	return spec.onClick ~= nil
end)) do
	r:GetScript("OnClick")(r)
	Tick(1.5)
end
ns.BookPages.GoBack()
Tick(1.5)
ns.BookPages.GoIndex()
Tick(1.5)
ns.BookPages.ShowRecipe(2657)
Tick(1.5)
ns.BookPages.RewriteRight()
Tick(0.5)
ns.BookPages.TurnIndex(1)
Tick(1.5)
-- Ctrl+Shift-click while the book is open turns to the item.
ctrl, shift = true, true
DressUpFrame = { IsShown = function() return false end }
events:Fire("GLOBAL_MOUSE_DOWN")
HandleModifiedItemClick("|cffffffff|Hitem:2589::::|h[Linen Cloth]|h|r")
ctrl, shift = false, false
Tick(1.5)
-- Escape closes it.
SourcebookBookEsc:GetScript("OnHide")()
Tick(1)
assert(not ns.Book.IsOpen(), "book did not close")
-- Close half a second into opening, then reopen: it must open properly, not "stay closed".
SlashCmdList.SOURCEBOOK("")
Tick(0.5)
ns.Book.Close()
Tick(1)
assert(not ns.Book.IsOpen(), "closed during opening")
Tick(3) -- the old swing must not come back and mark it open
assert(not ns.Book.IsOpen(), "a cancelled opening reopened itself")
SlashCmdList.SOURCEBOOK("")
Tick(3)
assert(ns.Book.IsOpen() and not ns.Book.IsBusy(), "reopen after a cancelled opening")
-- Close in the middle of a turn, reopen, and turn again.
ns.BookPages.GoItem(2770)
Tick(0.4)
ns.Book.Close()
Tick(1)
SlashCmdList.SOURCEBOOK("")
Tick(3)
assert(ns.Book.IsOpen() and not ns.Book.IsBusy(), "reopen after closing mid-turn")
ns.BookPages.GoItem(2589)
Tick(2)
assert(not ns.Book.IsBusy(), "turn after a mid-turn close")
-- An error inside an animation tears the book down and falls back to the plain window.
local realGather = ns.Tooltip.Gather
ns.Tooltip.Gather = function()
	error("boom")
end
local reported
local oldHandler = geterrorhandler
geterrorhandler = function()
	return function(err)
		reported = err
	end
end
ns.Tooltip.Gather = realGather
local panelShown
local realPanelItem = ns.Panel.ShowItem
ns.Panel.ShowItem = function(id)
	panelShown = id
end
ns.Book.Turn(1, function()
	error("boom in a builder")
end)
Tick(2)
assert(reported and tostring(reported):find("boom in a builder"), "the error was not reported")
assert(not ns.Book.IsOpen() and not ns.Book.IsBusy(), "the book was not put away after an error")
assert(panelShown == 2589, "the plain window did not take over")
ns.Panel.ShowItem = realPanelItem
geterrorhandler = oldHandler
-- And it opens again normally afterwards.
SlashCmdList.SOURCEBOOK("")
Tick(3)
assert(ns.Book.IsOpen() and not ns.Book.IsBusy(), "reopen after an error")
SlashCmdList.SOURCEBOOK("classic")
SlashCmdList.SOURCEBOOK("book off")
assert(ns.db.settings.book == false)
SlashCmdList.SOURCEBOOK("2589")

local function eq(a, b, msg)
	local function same(x, y)
		if type(x) ~= type(y) then
			return false
		end
		if type(x) ~= "table" then
			return x == y
		end
		for k, v in pairs(x) do
			if not same(v, y[k]) then
				return false
			end
		end
		for k in pairs(y) do
			if x[k] == nil then
				return false
			end
		end
		return true
	end
	if not same(a, b) then
		local function show(v)
			if type(v) == "table" then
				local parts = {}
				for _, x in ipairs(v) do
					parts[#parts + 1] = tostring(x)
				end
				return "{" .. table.concat(parts, ", ") .. "}"
			end
			return tostring(v)
		end
		error((msg or "eq") .. ": expected " .. show(b) .. ", got " .. show(a), 2)
	end
end

-- Navigation: the path that used to strand you (open, click an item, go back), and every way
-- of moving around.
SlashCmdList.SOURCEBOOK("book on")
local Pages = ns.BookPages
local function Kind()
	local c = Pages.Current()
	return c and c.kind, c and c.id
end
if ns.Book.IsOpen() then
	ns.Book.Close()
	Tick(1)
end
SlashCmdList.SOURCEBOOK("")
Tick(3)
local root = SourcebookBook
local keyDown = root:GetScript("OnKeyDown")
assert(keyDown, "the book takes keys")
local propagate = {}
rawset(root, "SetPropagateKeyboardInput", function(_, on)
	propagate[#propagate + 1] = on
end)
local function Press(key)
	propagate = {}
	keyDown(root, key)
	Tick(1.5)
	return propagate[#propagate]
end
Pages.GoIndex()
Tick(1.5)
eq(Kind(), "index")
Pages.GoItem(2770)
Tick(1.5)
eq({ Kind() }, { "item", 2770 })
-- Back through the on-page link: find "‹ Back" among the links and click it.
local backLink
for _, f in ipairs(frames) do
	local text = rawget(f, "text")
	if text and rawget(f, "onClick") == Pages.GoBack then
		backLink = f
	end
end
assert(backLink, "no Back link on the page")
backLink:GetScript("OnClick")(backLink, "LeftButton")
Tick(1.5)
eq(Kind(), "index", "Back link returns to the index")
-- Forward, then back with Backspace, right-click and mouse 4; forward with mouse 5.
Pages.GoForward()
Tick(1.5)
eq({ Kind() }, { "item", 2770 })
eq(Press("BACKSPACE"), false, "Backspace is used, not passed to the game")
eq(Kind(), "index")
root:GetScript("OnMouseUp")(root, "Button5")
Tick(1.5)
eq({ Kind() }, { "item", 2770 })
root:GetScript("OnMouseUp")(root, "RightButton")
Tick(1.5)
eq(Kind(), "index")
-- A right-click on a row also goes back (rows don't swallow it).
Pages.GoItem(2589)
Tick(1.5)
local anyRow
for _, f in ipairs(frames) do
	if rawget(f, "wash") and rawget(f, "spec") then -- a book row (the plain window's rows have no wash)
		anyRow = f
	end
end
anyRow:GetScript("OnClick")(anyRow, "Button4")
Tick(1.5)
eq(Kind(), "index", "mouse 4 on a row goes back")
-- Breadcrumbs: index -> 2770 -> recipe 2657 -> 2840; jump two back to 2770.
Pages.GoItem(2770)
Tick(1.5)
Pages.GoRecipe(2657)
Tick(1.5)
Pages.GoItem(2840)
Tick(1.5)
Pages.GoCrumb(2)
Tick(1.5)
eq({ Kind() }, { "item", 2770 }, "breadcrumb jump")
Pages.GoForward()
Tick(1.5)
eq({ Kind() }, { "recipe", 2657 }, "forward walks back along the trail")
-- Arrows page the index, Home goes to the index, other keys pass through.
eq(Press("HOME"), false)
eq(Kind(), "index")
assert((Pages.Current().query or "") ~= "", "Home returns to your last search")
Pages.Go(Pages.Index())
Tick(1.5)
local before = Pages.Current().page
assert(Pages.Current().pages > 1, "the full index spans many pages")
Press("RIGHT")
eq(Pages.Current().page, before + 1, "Right arrow turns the index page")
Press("LEFT")
eq(Pages.Current().page, before, "Left arrow turns it back")
eq(Press("W"), true, "movement keys reach the game")
-- In combat the book leaves the keyboard alone entirely.
inCombat = true
propagate = {}
keyDown(root, "BACKSPACE")
eq(#propagate, 0, "no keyboard calls in combat")
eq(Kind(), "index", "Backspace in combat does nothing to the book")
inCombat = false
-- Search: Enter opens the best match; Escape clears the text first.
local box
for _, f in ipairs(frames) do
	if f:GetScript("OnEnterPressed") and f:GetScript("OnTextChanged") then
		box = f
	end
end
local typed = "copper ore"
rawset(box, "GetText", function()
	return typed
end)
rawset(box, "SetText", function(_, t)
	typed = t
end)
box:GetScript("OnTextChanged")(box, true)
Tick(1)
box:GetScript("OnEnterPressed")(box)
Tick(1.5)
eq({ Kind() }, { "item", 2770 }, "Enter opens the best match")
Pages.GoBack()
Tick(1.5)
box:GetScript("OnEscapePressed")(box)
eq(typed, "", "Escape clears the search")
eq(Pages.Current().query, "")
-- History survives closing: reopen lands where you were, and Back still works.
Pages.GoItem(2318)
Tick(1.5)
ns.Book.Close()
Tick(1)
SlashCmdList.SOURCEBOOK("")
Tick(3)
eq({ Kind() }, { "item", 2318 }, "reopens where you left off")
Pages.GoBack()
Tick(1.5)
eq(Kind(), "index", "Back works after reopening")
-- Ctrl+Shift-click while closed opens onto the item, with Back to where you were.
ns.Book.Close()
Tick(1)
ns.ShowItem(4306)
Tick(3)
eq({ Kind() }, { "item", 4306 })
Pages.GoBack()
Tick(1.5)
eq(Kind(), "index")
