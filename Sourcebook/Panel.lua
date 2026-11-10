-- Sourcebook: the lookup window. Three views: search, an item (where it comes from, what it
-- crafts) and a recipe (reagents you have and still need, and what to craft first).

local _, ns = ...

local Panel = {}
ns.Panel = Panel

local WIDTH, HEIGHT, ROW_H = 460, 540, 18
local frame, scroll, content, title, backButton, searchBox
local rows = {}
local history = {}
local current
local refreshPending = false
local planTimes = 1

-- ---------------------------------------------------------------- game lookups

local function ItemName(id)
	return ns.Format.names.item(id)
end

local function ItemIcon(id)
	local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
	return icon or 134400 -- question mark
end

local function SpellIcon(id)
	local good, icon = pcall(C_Spell.GetSpellTexture, id)
	return good and icon or 134400
end

local function Have(id)
	local good, n = pcall(C_Item.GetItemCount, id, true)
	return good and n or 0
end

-- ---------------------------------------------------------------- rows

local function RowTooltip(row)
	if not row.spec.tooltip then
		return
	end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	row.spec.tooltip(GameTooltip)
	GameTooltip:Show()
end

local function MakeRow(i)
	local row = CreateFrame("Button", nil, content)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
	row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ROW_H - 2, ROW_H - 2)
	row.icon:SetPoint("LEFT", 2, 0)
	row.left = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.left:SetJustifyH("LEFT")
	row.left:SetWordWrap(false)
	row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.right:SetJustifyH("RIGHT")
	row.right:SetPoint("RIGHT", -4, 0)
	row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
	row:SetScript("OnClick", function(self)
		if self.spec.onClick then
			self.spec.onClick()
		end
	end)
	row:SetScript("OnEnter", RowTooltip)
	row:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	rows[i] = row
	return row
end

-- specs: { header = true, text } or { text, right, icon, indent, color, onClick, tooltip }
local function Render(specs)
	for i, spec in ipairs(specs) do
		local row = rows[i] or MakeRow(i)
		row.spec = spec
		row:Show()
		row.left:ClearAllPoints()
		if spec.icon then
			row.icon:SetTexture(spec.icon)
			row.icon:Show()
			row.icon:SetPoint("LEFT", 2 + (spec.indent or 0), 0)
			row.left:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		else
			row.icon:Hide()
			row.left:SetPoint("LEFT", 4 + (spec.indent or 0), 0)
		end
		row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
		row.left:SetFontObject(spec.header and "GameFontNormal" or "GameFontHighlightSmall")
		row.left:SetText(spec.text or "")
		row.right:SetText(spec.right or "")
		local c = spec.color
		if c then
			row.left:SetTextColor(c[1], c[2], c[3])
		elseif not spec.header then
			row.left:SetTextColor(1, 1, 1)
		end
		row:EnableMouse(spec.onClick ~= nil or spec.tooltip ~= nil)
	end
	for i = #specs + 1, #rows do
		rows[i]:Hide()
	end
	content:SetHeight(math.max(1, #specs * ROW_H))
end

-- ---------------------------------------------------------------- views

local function Navigate(view, noHistory)
	if current and not noHistory then
		history[#history + 1] = current
	end
	if view.kind == "recipe" and not (current and current.kind == "recipe" and current.id == view.id) then
		planTimes = 1
	end
	current = view
	Panel.Refresh()
	scroll:SetVerticalScroll(0)
end

local function ZonesTooltip(entry)
	return function(tip)
		tip:AddLine(entry.name or "?", 1, 0.82, 0)
		for _, loc in ipairs(entry.locations or {}) do
			local where = loc.instance and ns.Format.names.instance(loc.instance) or ns.Format.names.zone(loc.map)
			tip:AddDoubleLine(where, loc.count .. (loc.count == 1 and " spawn" or " spawns"), 1, 1, 1, 0.7, 0.7, 0.7)
		end
		if entry.m then
			tip:AddLine("You looted it in " .. ns.Format.names.zone(entry.m), 1, 1, 1)
		end
		tip:AddLine("Click: waypoint to the nearest spot", 0.45, 0.45, 0.45)
	end
end

local function RecipeLabel(r)
	return ns.Format.names.spell(r.spell), ns.Format.names.profession(r.skill) .. " " .. r.orange
end

local function ItemView(itemID)
	local specs = {}
	local c = ns.Tooltip.Gather(itemID)
	local map, px, py = ns.Waypoint.PlayerPosition()
	for _, group in ipairs(c.info.groups) do
		local label = group.label
		if group.total > #group.entries then
			label = label .. string.format(" (best %d of %d)", #group.entries, group.total)
		end
		specs[#specs + 1] = { header = true, text = label }
		local entries = group.entries
		if group.key == "v" then
			entries = ns.Sources.SortByDistance({ unpack(entries) }, map, px, py)
		end
		for _, e in ipairs(entries) do
			local text, stat = ns.Format.Entry(group, e)
			local spec = { text = text, right = stat, indent = 8 }
			if group.key == "c" then
				spec.icon = ItemIcon(e.id)
				spec.onClick = function()
					Navigate({ kind = "item", id = e.id })
				end
			elseif e.locations or e.m then
				spec.onClick = function()
					if not ns.Waypoint.ToEntry(e) then
						print("|cff88ccffSourcebook|r: no map spot for " .. (e.name or "that") .. " (it may be inside an instance).")
					end
				end
				spec.tooltip = ZonesTooltip(e)
			end
			specs[#specs + 1] = spec
		end
	end
	local craft = c.craft
	if craft.teaches then
		specs[#specs + 1] = { header = true, text = "Teaches" }
		local name, rank = RecipeLabel(craft.teaches)
		specs[#specs + 1] = { text = name, right = rank, icon = SpellIcon(craft.teaches.spell), indent = 8,
			color = ns.Knows(craft.teaches.spell) and { 0.4, 0.9, 0.4 } or nil,
			onClick = function()
				Navigate({ kind = "recipe", id = craft.teaches.spell })
			end }
	end
	if #craft.createdBy > 0 then
		specs[#specs + 1] = { header = true, text = "Crafted with" }
		for _, r in ipairs(craft.createdBy) do
			local name, rank = RecipeLabel(r)
			specs[#specs + 1] = { text = name, right = rank, icon = SpellIcon(r.spell), indent = 8, onClick = function()
				Navigate({ kind = "recipe", id = r.spell })
			end }
		end
	end
	if #craft.usedIn > 0 then
		specs[#specs + 1] = { header = true, text = "Reagent for " .. #craft.usedIn .. " recipes" }
		for _, r in ipairs(craft.usedIn) do
			local name, rank = RecipeLabel(r)
			specs[#specs + 1] = { text = name, right = rank, icon = r.item > 0 and ItemIcon(r.item) or SpellIcon(r.spell),
				indent = 8, onClick = function()
					Navigate({ kind = "recipe", id = r.spell })
				end }
		end
	end
	if #specs == 0 then
		specs[1] = { text = "No sources known for this item yet. Loot it once and Sourcebook will remember where." }
	end
	return ItemName(itemID), ItemIcon(itemID), specs
end

local function RecipeView(spellID)
	local r = ns.Codec.Recipe(spellID)
	if not r then
		return "Unknown recipe", 134400, { { text = "Sourcebook has no data for this recipe." } }
	end
	local specs = {}
	local prof = ns.Format.names.profession(r.skill)
	specs[#specs + 1] = { text = string.format("%s: |cffff8040%d|r |cffffff00%d|r |cff40c040%d|r", prof, r.orange, r.yellow, r.gray),
		color = { 1, 0.82, 0 } }
	if ns.Knows(spellID) then
		specs[#specs + 1] = { text = "You know this recipe.", color = { 0.4, 0.9, 0.4 } }
	end
	if r.item > 0 then
		specs[#specs + 1] = { text = "Makes: " .. ItemName(r.item), right = r.count > 1 and (r.count .. "x") or "",
			icon = ItemIcon(r.item), onClick = function()
				Navigate({ kind = "item", id = r.item })
			end }
	end
	if r.learnedFrom > 0 then
		specs[#specs + 1] = { text = "Learned from: " .. ItemName(r.learnedFrom), icon = ItemIcon(r.learnedFrom),
			right = "where?", onClick = function()
				Navigate({ kind = "item", id = r.learnedFrom })
			end }
	else
		specs[#specs + 1] = { text = "Learned from a trainer (or automatically)", color = { 0.7, 0.7, 0.7 } }
	end
	specs[#specs + 1] = { header = true, text = "Reagents (one craft)" }
	for _, reagent in ipairs(r.reagents) do
		local have = Have(reagent.item)
		local enough = have >= reagent.count
		specs[#specs + 1] = { text = ItemName(reagent.item), icon = ItemIcon(reagent.item), indent = 8,
			right = (enough and "|cff66dd66" or "|cffff6666") .. have .. "/" .. reagent.count .. "|r",
			onClick = function()
				Navigate({ kind = "item", id = reagent.item })
			end }
	end
	local plan = ns.Craft.Plan(spellID, planTimes, Have)
	specs[#specs + 1] = { header = true, text = string.format("Plan for crafting it %d %s", planTimes, planTimes == 1 and "time" or "times") }
	specs[#specs + 1] = { text = "|cff88ccffOne more|r (Shift-click: ten more)", indent = 8, onClick = function()
		planTimes = math.min(500, planTimes + (IsShiftKeyDown() and 10 or 1))
		Panel.Refresh()
	end }
	if planTimes > 1 then
		specs[#specs + 1] = { text = "|cff88ccffBack to one|r", indent = 8, onClick = function()
			planTimes = 1
			Panel.Refresh()
		end }
	end
	if #plan.steps > 1 then
		for _, step in ipairs(plan.steps) do
			specs[#specs + 1] = { text = "Craft " .. ns.Format.names.spell(step.spell), right = step.crafts .. "x",
				icon = SpellIcon(step.spell), indent = 8, onClick = step.spell ~= spellID and function()
					Navigate({ kind = "recipe", id = step.spell })
				end or nil }
		end
	end
	local missingAny = false
	for _, line in ipairs(plan.raw) do
		if line.missing > 0 then
			missingAny = true
			specs[#specs + 1] = { text = "Get " .. ItemName(line.item), icon = ItemIcon(line.item), indent = 8,
				right = string.format("|cffff6666%d|r more (%d/%d)", line.missing, line.have, line.need),
				onClick = function()
					Navigate({ kind = "item", id = line.item })
				end }
		end
	end
	if not missingAny then
		specs[#specs + 1] = { text = "You have everything for this.", indent = 8, color = { 0.4, 0.9, 0.4 } }
	end
	local name = ns.Format.names.spell(spellID)
	return name, r.item > 0 and ItemIcon(r.item) or SpellIcon(spellID), specs
end

local function SearchView(text)
	local specs = {}
	if not text or text == "" then
		specs[1] = { text = "Type an item name, or Alt-click any item link.", color = { 0.7, 0.7, 0.7 } }
		local recent = ns.db.recent or {}
		if #recent > 0 then
			specs[#specs + 1] = { header = true, text = "Recent" }
			for _, id in ipairs(recent) do
				specs[#specs + 1] = { text = ItemName(id), icon = ItemIcon(id), onClick = function()
					Navigate({ kind = "item", id = id })
				end }
			end
		end
		return "Sourcebook", 133740, specs
	end
	local ids = ns.Sources.Search(text, 80)
	for _, id in ipairs(ids) do
		specs[#specs + 1] = { text = ItemName(id), icon = ItemIcon(id), onClick = function()
			Navigate({ kind = "item", id = id })
		end }
	end
	if #specs == 0 then
		specs[1] = { text = "No items match.", color = { 0.7, 0.7, 0.7 } }
	end
	return "Sourcebook", 133740, specs
end

local function Remember(itemID)
	local recent = ns.db.recent
	for i = #recent, 1, -1 do
		if recent[i] == itemID then
			table.remove(recent, i)
		end
	end
	table.insert(recent, 1, itemID)
	while #recent > 12 do
		table.remove(recent)
	end
end

function Panel.Refresh()
	if not frame or not current then
		return
	end
	local name, icon, specs
	if current.kind == "item" then
		Remember(current.id)
		name, icon, specs = ItemView(current.id)
		searchBox:Hide()
	elseif current.kind == "recipe" then
		name, icon, specs = RecipeView(current.id)
		searchBox:Hide()
	else
		name, icon, specs = SearchView(current.text)
		searchBox:Show()
	end
	title:SetText(name)
	frame.icon:SetTexture(icon)
	backButton:SetEnabled(#history > 0)
	scroll:ClearAllPoints()
	scroll:SetPoint("TOPLEFT", 12, current.kind == "search" and -88 or -60)
	scroll:SetPoint("BOTTOMRIGHT", -30, 12)
	content:SetWidth(scroll:GetWidth())
	Render(specs)
end

-- Item names arrive from the server a moment after first use; redraw once they do.
function Panel.OnItemInfo()
	if frame and frame:IsShown() and not refreshPending then
		refreshPending = true
		C_Timer.After(0.2, function()
			refreshPending = false
			Panel.Refresh()
		end)
	end
end

-- ---------------------------------------------------------------- frame

local function Build()
	frame = CreateFrame("Frame", "SourcebookFrame", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	tinsert(UISpecialFrames, "SourcebookFrame")

	local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("TOP", 0, -6)
	label:SetText("Sourcebook")

	backButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	backButton:SetSize(50, 20)
	backButton:SetPoint("TOPLEFT", 10, -30)
	backButton:SetText("Back")
	backButton:SetScript("OnClick", function()
		local prev = table.remove(history)
		if prev then
			current = prev
			Panel.Refresh()
			scroll:SetVerticalScroll(0)
		end
	end)

	local searchButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	searchButton:SetSize(60, 20)
	searchButton:SetPoint("TOPRIGHT", -10, -30)
	searchButton:SetText("Search")
	searchButton:SetScript("OnClick", function()
		Navigate({ kind = "search", text = searchBox:GetText() })
		searchBox:SetFocus()
	end)

	frame.icon = frame:CreateTexture(nil, "ARTWORK")
	frame.icon:SetSize(22, 22)
	frame.icon:SetPoint("LEFT", backButton, "RIGHT", 8, 0)
	title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("LEFT", frame.icon, "RIGHT", 6, 0)
	title:SetPoint("RIGHT", searchButton, "LEFT", -6, 0)
	title:SetJustifyH("LEFT")
	title:SetWordWrap(false)

	searchBox = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
	searchBox:SetSize(WIDTH - 40, 22)
	searchBox:SetPoint("TOPLEFT", 20, -58)
	searchBox:SetScript("OnTextChanged", function(self, userInput)
		SearchBoxTemplate_OnTextChanged(self)
		if userInput and current and current.kind == "search" then
			current.text = self:GetText()
			Panel.Refresh()
		end
	end)

	scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(WIDTH - 42, 1)
	scroll:SetScrollChild(content)
end

function Panel.ShowItem(itemID)
	if not frame then
		Build()
	end
	frame:Show()
	Navigate({ kind = "item", id = itemID })
end

function Panel.ShowRecipe(spellID)
	if not frame then
		Build()
	end
	frame:Show()
	Navigate({ kind = "recipe", id = spellID })
end

function Panel.ShowSearch(text)
	if not frame then
		Build()
	end
	frame:Show()
	searchBox:SetText(text or "")
	Navigate({ kind = "search", text = text or "" })
	searchBox:SetFocus()
end

function Panel.Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
	else
		Panel.ShowSearch("")
	end
end
