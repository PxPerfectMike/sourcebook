-- Sourcebook: what is written on the book's pages. Three kinds of spread:
--   index   search, category, sort, and the matching items, a page at a time
--   item    where an item comes from (every source a waypoint) and what it crafts
--   recipe  reagents with what you have, and a plan for crafting it N times
-- Moving between them turns the page; the ribbon and history turn it back.

local ADDON, ns = ...

local Pages = {}
ns.BookPages = Pages

local Book, Library, Format = ns.Book, ns.Library, ns.Format

local nav = ns.Nav.New() -- back, forward and the breadcrumb trail; lives all session
local fonts
local searchTimer

-- ---------------------------------------------------------------- fonts and page widgets

local function Fonts()
	if fonts then
		return fonts
	end
	local _, H = Book.Size()
	local titleFile = (QuestTitleFont and QuestTitleFont:GetFont()) or "Fonts\\MORPHEUS.TTF"
	local bodyFile = (QuestFont and QuestFont:GetFont()) or "Fonts\\FRIZQT__.TTF"
	local function Make(name, file, size)
		local f = CreateFont(name)
		f:SetFont(file, size, "")
		f:SetShadowColor(1, 0.95, 0.8, 0.25)
		f:SetShadowOffset(0.6, -0.6)
		return f
	end
	fonts = {
		title = Make("SourcebookBookTitle", titleFile, math.floor(H * 0.040)),
		heading = Make("SourcebookBookHeading", titleFile, math.floor(H * 0.026)),
		body = Make("SourcebookBookBody", bodyFile, math.floor(H * 0.0195)),
		small = Make("SourcebookBookSmall", bodyFile, math.floor(H * 0.0165)),
	}
	fonts.rowH = math.floor(H * 0.030)
	return fonts
end

-- The writable area of a page: inside the printed border.
local INSET_X, INSET_TOP, INSET_BOTTOM = 0.115, 0.085, 0.075

local function PageArea(page)
	local w, h = page:GetSize()
	return w * INSET_X, h * INSET_TOP, w * (1 - 2 * INSET_X), h * (1 - INSET_TOP - INSET_BOTTOM)
end

-- A page holds pooled widgets; Begin() hides them and starts writing at the top.
local function Begin(page, keepSearch)
	page.widgets = page.widgets or {}
	for _, list in pairs(page.widgets) do
		for _, w in ipairs(list) do
			w:Hide()
		end
	end
	page.used = {}
	page.inkStrings = {}
	page.inkOthers = {}
	local x, y, w, h = PageArea(page)
	page.x, page.y, page.w, page.h = x, y, w, h
	page.cursor = 0
	page.inkStart, page.othersStart = nil, nil
	if page.search and not keepSearch then
		page.search:Hide()
	end
end

local function Take(page, kind, make)
	page.widgets[kind] = page.widgets[kind] or {}
	page.used[kind] = (page.used[kind] or 0) + 1
	local w = page.widgets[kind][page.used[kind]]
	if not w then
		w = make()
		page.widgets[kind][page.used[kind]] = w
	end
	w:Show()
	w:SetAlpha(1)
	return w
end

local function Remaining(page)
	return page.h - page.cursor
end

local function Text(page, text, font, color, opts)
	opts = opts or {}
	local fs = Take(page, "text", function()
		return page:CreateFontString(nil, "ARTWORK")
	end)
	fs:SetFontObject(font)
	fs:SetText(text)
	fs:SetJustifyH(opts.justify or "LEFT")
	fs:SetJustifyV("TOP")
	fs:SetWordWrap(opts.wrap ~= false)
	fs:SetSpacing(2)
	local c = color or Book.INK
	fs:SetTextColor(c[1], c[2], c[3])
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", page, "TOPLEFT", page.x + (opts.indent or 0), -(page.y + page.cursor))
	fs:SetWidth(page.w - (opts.indent or 0))
	if opts.wrap == false then
		fs:SetHeight(fs:GetLineHeight() + 2)
	else
		fs:SetHeight(0)
	end
	page.cursor = page.cursor + fs:GetStringHeight() + (opts.after or 4)
	page.inkStrings[#page.inkStrings + 1] = fs
	return fs
end

local function Space(page, h)
	page.cursor = page.cursor + h
end

local function Rule(page, opts)
	local t = Take(page, "rule", function()
		local tex = page:CreateTexture(nil, "ARTWORK")
		tex:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\rule.png")
		return tex
	end)
	t:ClearAllPoints()
	local inset = (opts and opts.inset) or page.w * 0.12
	t:SetPoint("TOPLEFT", page, "TOPLEFT", page.x + inset, -(page.y + page.cursor + 2))
	t:SetSize(page.w - 2 * inset, 8)
	page.cursor = page.cursor + 12
	page.inkOthers[#page.inkOthers + 1] = t
	return t
end

local function RowEnter(self)
	local spec = self.spec
	if spec.onClick or spec.item or spec.tooltip then
		self.wash:SetAlpha(0.22)
	end
	if spec.item then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetItemByID(spec.item)
		GameTooltip:Show()
	elseif spec.tooltip then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		spec.tooltip(GameTooltip)
		GameTooltip:Show()
	end
end

local function RowLeave(self)
	self.wash:SetAlpha(0)
	GameTooltip:Hide()
end

local function RowClick(self, button)
	if button and button ~= "LeftButton" then
		Pages.Mouse(button)
		return
	end
	local spec = self.spec
	if spec.onClick then
		local cx, cy = self:GetCenter()
		local rx, ry = Book.Root():GetLeft(), Book.Root():GetTop()
		Book.Burst(cx - rx, cy - ry, { count = 8, kind = "spark", speed = 50, spread = 20, life = 0.6, size = 12 })
		spec.onClick(self)
	end
end

-- spec: text, right, icon, color, indent, onClick, item (tooltip), tooltip(fn)
local function Row(page, spec)
	local f = Fonts()
	local b = Take(page, "row", function()
		local r = CreateFrame("Button", nil, page)
		r.wash = r:CreateTexture(nil, "BACKGROUND")
		r.wash:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\wash.png")
		r.wash:SetPoint("TOPLEFT", -6, 2)
		r.wash:SetPoint("BOTTOMRIGHT", 6, -2)
		r.wash:SetAlpha(0)
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetPoint("LEFT", 0, 0)
		r.ring = r:CreateTexture(nil, "OVERLAY")
		r.ring:SetTexture("Interface\\Buttons\\UI-Quickslot2")
		r.ring:SetPoint("CENTER", r.icon, "CENTER")
		r.ring:SetVertexColor(0.45, 0.30, 0.15)
		r.left = r:CreateFontString(nil, "ARTWORK")
		r.left:SetJustifyH("LEFT")
		r.left:SetWordWrap(false)
		r.right = r:CreateFontString(nil, "ARTWORK")
		r.right:SetJustifyH("RIGHT")
		r.right:SetWordWrap(false)
		r:RegisterForClicks("AnyUp")
		r:SetScript("OnEnter", RowEnter)
		r:SetScript("OnLeave", RowLeave)
		r:SetScript("OnClick", RowClick)
		return r
	end)
	b.spec = spec
	local h = f.rowH
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", page, "TOPLEFT", page.x + (spec.indent or 0), -(page.y + page.cursor))
	b:SetSize(page.w - (spec.indent or 0), h)
	local iconSize = h - 4
	b.icon:SetSize(iconSize, iconSize)
	b.ring:SetSize(iconSize * 1.75, iconSize * 1.75)
	b.left:SetFontObject(spec.font or f.body)
	b.right:SetFontObject(f.small)
	b.left:ClearAllPoints()
	if spec.icon then
		b.icon:SetTexture(spec.icon)
		b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		b.icon:Show()
		b.ring:Show()
		b.left:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
	else
		b.icon:Hide()
		b.ring:Hide()
		b.left:SetPoint("LEFT", 2, 0)
	end
	b.right:ClearAllPoints()
	b.right:SetPoint("RIGHT", -2, 0)
	b.left:SetPoint("RIGHT", b.right, "LEFT", -8, 0)
	b.left:SetText(spec.text or "")
	b.right:SetText(spec.right or "")
	local c = spec.color or Book.INK
	b.left:SetTextColor(c[1], c[2], c[3])
	b.right:SetTextColor(Book.INK_SOFT[1], Book.INK_SOFT[2], Book.INK_SOFT[3])
	b:EnableMouse(true) -- even plain rows pass right-click and mouse 4/5 on to the book
	page.cursor = page.cursor + h
	page.inkStrings[#page.inkStrings + 1] = b.left
	page.inkStrings[#page.inkStrings + 1] = b.right
	if spec.icon then
		page.inkOthers[#page.inkOthers + 1] = b.icon
		page.inkOthers[#page.inkOthers + 1] = b.ring
	end
	return b
end

local LINK_HOVER = { 0.55, 0.25, 0.05 }

local function LinkEnter(self)
	if self.onClick then
		self.text:SetTextColor(LINK_HOVER[1], LINK_HOVER[2], LINK_HOVER[3], 1)
	end
	if self.tip then
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(self.tip, 1, 0.82, 0)
		if self.tipKeys then
			GameTooltip:AddLine(self.tipKeys, 0.75, 0.75, 0.75)
		end
		GameTooltip:Show()
	end
end

local function LinkLeave(self)
	local c = self.color
	self.text:SetTextColor(c[1], c[2], c[3], self.alpha)
	GameTooltip:Hide()
end

local function LinkClick(self, button)
	if button and button ~= "LeftButton" then
		Pages.Mouse(button)
		return
	end
	if self.onClick then
		if PlaySound and SOUNDKIT then
			PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON or 1115)
		end
		self.onClick()
	end
end

-- One clickable word or phrase. l: text, onClick, selected, disabled, color, font, tip, keys.
-- Returns the widget, sized to its text but not yet placed.
local function MakeLink(page, l)
	local f = Fonts()
	local b = Take(page, "link", function()
		local btn = CreateFrame("Button", nil, page)
		btn.text = btn:CreateFontString(nil, "ARTWORK")
		btn.text:SetPoint("CENTER")
		btn.under = btn:CreateTexture(nil, "ARTWORK")
		btn.under:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\rule.png")
		btn.under:SetPoint("BOTTOMLEFT", 0, 0)
		btn.under:SetPoint("BOTTOMRIGHT", 0, 0)
		btn.under:SetHeight(6)
		btn:RegisterForClicks("AnyUp")
		btn:SetScript("OnClick", LinkClick)
		btn:SetScript("OnEnter", LinkEnter)
		btn:SetScript("OnLeave", LinkLeave)
		return btn
	end)
	b.text:SetFontObject(l.font or f.small)
	b.text:SetText(l.text)
	b.color = l.selected and LINK_HOVER or (l.color or Book.INK_SOFT)
	b.alpha = l.disabled and 0.32 or 1
	b.text:SetTextColor(b.color[1], b.color[2], b.color[3], b.alpha)
	b.under:SetShown(l.selected == true)
	b.onClick = (not l.disabled) and l.onClick or nil
	if l.disabled then
		b.tip, b.tipKeys = l.offTip or l.tip, l.offTip and nil or l.keys
	else
		b.tip, b.tipKeys = l.tip, l.keys
	end
	b:EnableMouse(true)
	b:SetSize(b.text:GetStringWidth() + 6, f.rowH)
	page.inkStrings[#page.inkStrings + 1] = b.text
	if l.selected then
		page.inkOthers[#page.inkOthers + 1] = b.under
	end
	return b
end

-- Words in a line, each clickable (category chips, sort), wrapping onto more lines as needed.
local function Links(page, links)
	local f = Fonts()
	local x = 0
	local gap = 10
	for _, l in ipairs(links) do
		local b = MakeLink(page, l)
		local w = b:GetWidth()
		if x > 0 and x + w > page.w then
			x = 0
			page.cursor = page.cursor + f.rowH
		end
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", page, "TOPLEFT", page.x + x, -(page.y + page.cursor))
		x = x + w + gap
	end
	page.cursor = page.cursor + f.rowH + 2
end

-- One line with links pinned left and right (and optionally centered), at a given height.
local function LinkLine(page, y, lefts, rights, center)
	local x = 0
	for _, l in ipairs(lefts or {}) do
		local b = MakeLink(page, l)
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", page, "TOPLEFT", page.x + x, -(page.y + y))
		x = x + b:GetWidth() + (l.gap or 10)
	end
	local rx = 0
	for _, l in ipairs(rights or {}) do
		local b = MakeLink(page, l)
		b:ClearAllPoints()
		b:SetPoint("TOPRIGHT", page, "TOPLEFT", page.x + page.w - rx, -(page.y + y))
		rx = rx + b:GetWidth() + 10
	end
	if center then
		local b = MakeLink(page, center)
		b:ClearAllPoints()
		b:SetPoint("TOP", page, "TOPLEFT", page.x + page.w / 2, -(page.y + y))
	end
end

-- ---------------------------------------------------------------- data helpers

local KIND_ICON = {
	learned = "Interface\\Icons\\INV_Misc_Book_09",
	M = "Interface\\Icons\\Trade_Mining",
	H = "Interface\\Icons\\Trade_Herbalism",
	F = "Interface\\Icons\\Trade_Fishing",
	d = "Interface\\Icons\\INV_Misc_Bag_10",
	k = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
	p = "Interface\\Icons\\INV_Misc_Bag_11",
	C = "Interface\\Icons\\INV_Box_01",
	O = "Interface\\Icons\\INV_Box_02",
	f = "Interface\\Icons\\Trade_Fishing",
	v = "Interface\\Icons\\INV_Misc_Coin_01",
}

local function ItemIcon(id)
	return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)) or 134400
end

-- A recipe shows what it makes; tradeskill spells themselves only have a generic icon.
local function RecipeIcon(r)
	if r and r.item and r.item > 0 then
		return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(r.item)) or 134400
	end
	local good, icon = pcall(C_Spell.GetSpellTexture, r and r.spell)
	return good and icon or 134400
end

local function SpellIcon(id)
	local good, icon = pcall(C_Spell.GetSpellTexture, id)
	return good and icon or 134400
end

local function Quality(id)
	local m = Library.Meta(id)
	local q = m and m.quality
	if not q and C_Item and C_Item.GetItemQualityByID then
		q = C_Item.GetItemQualityByID(id)
	end
	return q or 1
end

local function QualityInk(id)
	return Book.QUALITY_INK[Quality(id)] or Book.INK
end

local function Have(id)
	local good, n = pcall(C_Item.GetItemCount, id, true)
	return good and n or 0
end

local CLASS_NAME = { [0] = "Consumable", [1] = "Container", [2] = "Weapon", [4] = "Armor", [5] = "Reagent",
	[7] = "Trade Goods", [9] = "Recipe", [12] = "Quest", [15] = "Miscellaneous" }

local function TypeLine(id)
	local m = Library.Meta(id)
	if not m then
		return nil
	end
	local parts = { CLASS_NAME[m.class] or "Item" }
	if m.itemLevel > 0 then
		parts[#parts + 1] = "Item Level " .. m.itemLevel
	end
	if m.requiredLevel > 0 then
		parts[#parts + 1] = "Requires Level " .. m.requiredLevel
	end
	return table.concat(parts, "  ·  ")
end

-- One sentence: the easiest way to get it.
local WEAK_SOURCE = { c = true, C = true, O = true, f = true }

local function Summary(info, craft)
	local g = info.groups[1]
	-- A crafted item whose only other sources are luck (gift boxes, chests, fishing): say craft it.
	local made = craft.createdBy[1]
	if made and (not g or WEAK_SOURCE[g.key]) then
		return "Craft it: " .. Format.names.spell(made.spell) .. " (" .. Format.names.profession(made.skill) .. " " .. made.orange .. ")."
	end
	if g then
		local e = g.entries[1]
		local where = Format.Where(e, 2)
		local verbs = {
			learned = "You have found it on", M = "Mine it from", H = "Gather it from", F = "Fish it from",
			d = "Most easily taken from", k = "Skin it from", p = "Pick it from the pockets of", C = "Look for it in",
			O = "Look for it in", c = "Open", f = "Fish for it in", v = "Buy it from",
		}
		local name = (g.key == "c" and Format.names.item(e.id)) or (g.key == "f" and Format.names.area(e.id)) or e.name or "?"
		local s = (verbs[g.key] or "Find it with") .. " " .. name
		if where and g.key ~= "f" then
			s = s .. ", in " .. where
		end
		return s .. "."
	end
	if craft.createdBy[1] then
		return "Crafted: " .. Format.names.spell(craft.createdBy[1].spell) .. "."
	end
	return "No one has written down where this comes from yet. Loot it once and the book will remember."
end

-- ---------------------------------------------------------------- spreads

-- ---------------------------------------------------------------- navigation rows

local function Clip(text, n)
	if #text <= n then
		return text
	end
	return text:sub(1, n - 1):gsub("%s+$", "") .. "…"
end

local function CrumbLabel(state, n)
	n = n or 18
	if state.kind == "index" then
		return (state.query and state.query ~= "") and ("\"" .. Clip(state.query, n - 4) .. "\"") or "Index"
	elseif state.kind == "item" then
		return Clip(Format.names.item(state.id), n)
	end
	return Clip(Format.names.spell(state.id), n)
end

-- The top of every spread: Back and Index on the left page; the trail and Forward on the right.
-- Disabled links stay in place, faded, so nothing jumps around between spreads.
local function SpreadNav(left, right)
	local f = Fonts()
	local cur = nav.current or {}
	LinkLine(left, 0, {
		{ text = "‹ Back", disabled = not nav:CanBack(), onClick = Pages.GoBack, tip = "Back",
			offTip = "Nothing to go back to yet",
			keys = "Backspace, right-click, or mouse button 4" },
	}, {
		{ text = "Index", disabled = cur.kind == "index", onClick = Pages.GoIndex, tip = "The index of every item",
			offTip = "You're in the index",
			keys = "Home, or the red ribbon" },
	})
	-- The trail gets whatever width Forward leaves; the oldest steps drop off until it fits.
	local measure = right.measure
	if not measure then
		measure = right:CreateFontString(nil, "ARTWORK")
		measure:Hide()
		right.measure = measure
	end
	measure:SetFontObject(f.small)
	local function Width(text)
		measure:SetText(text)
		return measure:GetStringWidth() + 6
	end
	local room = right.w - Width("Forward ›") - 12
	local crumbs = nav:Crumbs(3)
	local clip = 18
	local function TrailWidth(list, ellipsis)
		local w = ellipsis and (Width("… ›") + 4) or 0
		for i, c in ipairs(list) do
			w = w + Width(CrumbLabel(c.state, clip)) + 4
			if i < #list then
				w = w + Width("›") + 4
			end
		end
		return w
	end
	-- Too long: shorten the names a little, then let the oldest steps go.
	while TrailWidth(crumbs, #nav.back > #crumbs - 1) > room do
		if clip > 11 then
			clip = clip - 2
		elseif #crumbs > 1 then
			table.remove(crumbs, 1)
			clip = 18
		else
			break
		end
	end
	local trail = {}
	if #nav.back > #crumbs - 1 then
		trail[#trail + 1] = { text = "… ›", gap = 4 }
	end
	for i, c in ipairs(crumbs) do
		local steps = c.steps
		trail[#trail + 1] = {
			text = CrumbLabel(c.state, clip),
			color = steps == 0 and Book.INK or Book.INK_SOFT,
			onClick = steps > 0 and function()
				Pages.GoCrumb(steps)
			end or nil,
			tip = steps > 0 and "Turn back to here" or nil,
			gap = 4,
		}
		if i < #crumbs then
			trail[#trail + 1] = { text = "›", gap = 4 }
		end
	end
	LinkLine(right, 0, trail, {
		{ text = "Forward ›", disabled = not nav:CanForward(), onClick = Pages.GoForward, tip = "Forward",
			offTip = "Nothing ahead: go back first",
			keys = "Mouse button 5" },
	})
	left.cursor = f.rowH + 8
	right.cursor = f.rowH + 8
	left.navTop = left.cursor
	right.navTop = right.cursor
end

local function FooterHeight()
	return Fonts().rowH + 4
end

-- The foot of every spread: page numbers like a real book, and Previous/Next page when a view
-- runs over more than one spread.
local function Footers(left, right, at, total)
	local f = Fonts()
	local y = left.h - f.rowH
	local paged = total > 1
	LinkLine(left, y, paged and {
		{ text = "‹ Previous page", disabled = at <= 1, onClick = function()
			Pages.TurnPage(-1)
		end, tip = "Previous page", keys = "Left arrow, Page Up, or the mouse wheel" },
	} or nil, nil, { text = "~ " .. (at * 2 - 1) .. " ~", color = Book.INK_SOFT })
	LinkLine(right, y, nil, paged and {
		{ text = "Next page ›", disabled = at >= total, onClick = function()
			Pages.TurnPage(1)
		end, tip = "Next page", keys = "Right arrow, Page Down, or the mouse wheel" },
	} or nil, { text = "~ " .. (at * 2) .. " ~", color = Book.INK_SOFT })
end

local function IndexSpread(state)
	return function(buffer)
		local f = Fonts()
		local left, right = buffer.left, buffer.right
		Begin(left, true)
		Begin(right)
		SpreadNav(left, right)
		right.inkStart, right.othersStart = #right.inkStrings + 1, #right.inkOthers + 1
		Text(left, "Sourcebook", f.title, Book.INK, { justify = "CENTER", after = 0 })
		Text(left, "of Things & Where They Hide", f.small, Book.INK_SOFT, { justify = "CENTER", after = 10 })
		Pages.SearchBox(left, state)
		local chips = {}
		for _, cat in ipairs(Library.CATEGORIES) do
			chips[#chips + 1] = { text = Library.CATEGORY_LABEL[cat], selected = state.category == cat, onClick = function()
				state.category, state.page = cat, 1
				Pages.Refresh()
			end }
		end
		Links(left, chips)
		local sorts = { { text = "Sort:", color = Book.INK_SOFT } }
		for _, key in ipairs(Library.SORTS) do
			sorts[#sorts + 1] = { text = Library.SORT_LABEL[key], selected = state.sort == key, onClick = function()
				state.sort, state.page = key, 1
				Pages.Refresh()
			end }
		end
		Links(left, sorts)
		local list = Pages.Browse(state.query, state.category, state.sort)
		state.count = #list
		Rule(left)
		local perLeft = math.floor((Remaining(left) - f.rowH - FooterHeight()) / f.rowH)
		local perRight = math.floor((Remaining(right) - FooterHeight()) / f.rowH)
		local per = perLeft + perRight
		local slice, page, pages = Library.Page(list, per, state.page)
		state.page, state.pages = page, pages
		-- Typing rewrites only from here down.
		left.inkStart, left.othersStart = #left.inkStrings + 1, #left.inkOthers + 1
		local count = (#list == 0 and "Nothing in the book by that name.") or (#list == 1 and "1 entry") or
			((BreakUpLargeNumbers and BreakUpLargeNumbers(#list) or #list) .. " entries")
		if pages > 1 then
			count = count .. "  ·  page " .. page .. " of " .. pages
		end
		Text(left, count, f.small, Book.INK_SOFT, { after = 2 })
		for i, id in ipairs(slice) do
			local target = i <= perLeft and left or right
			Row(target, {
				text = Format.names.item(id),
				icon = ItemIcon(id),
				color = QualityInk(id),
				item = id,
				onClick = function()
					Pages.GoItem(id)
				end,
			})
		end
		Footers(left, right, page, pages)
	end
end

local function Header(page, icon, name, color, sub)
	local f = Fonts()
	local t = Take(page, "bigicon", function()
		local tex = page:CreateTexture(nil, "ARTWORK")
		return tex
	end)
	local size = f.rowH * 2
	t:SetTexture(icon)
	t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	t:ClearAllPoints()
	t:SetPoint("TOPLEFT", page, "TOPLEFT", page.x, -(page.y + page.cursor))
	t:SetSize(size, size)
	page.inkOthers[#page.inkOthers + 1] = t
	local ring = Take(page, "bigring", function()
		local tex = page:CreateTexture(nil, "OVERLAY")
		tex:SetTexture("Interface\\Buttons\\UI-Quickslot2")
		tex:SetVertexColor(0.45, 0.30, 0.15)
		return tex
	end)
	ring:ClearAllPoints()
	ring:SetPoint("CENTER", t, "CENTER")
	ring:SetSize(size * 1.75, size * 1.75)
	page.inkOthers[#page.inkOthers + 1] = ring
	local top = page.cursor
	Text(page, name, f.heading, color, { indent = size + 10, after = 2 })
	if sub then
		Text(page, sub, f.small, Book.INK_SOFT, { indent = size + 10, after = 2 })
	end
	page.cursor = math.max(page.cursor, top + size) + 8
end

-- Elements for an item, as { kind, height, keep, draw(page) } so they can flow over pages.
local function ItemElements(id)
	local f = Fonts()
	local c = ns.Tooltip.Gather(id)
	local info, craft = c.info, c.craft
	local els = {}
	local function add(height, draw, keep)
		els[#els + 1] = { h = height, draw = draw, keep = keep }
	end
	local map, px, py = ns.Waypoint.PlayerPosition()
	for _, group in ipairs(info.groups) do
		local label = group.label
		if group.total > #group.entries then
			label = label .. string.format("  (best %d of %d)", #group.entries, group.total)
		end
		add(f.rowH + 6, function(page)
			Space(page, 4)
			Text(page, label, f.heading, Book.INK, { wrap = false, after = 2 })
		end, true)
		local entries = group.entries
		if group.key == "v" then
			entries = ns.Sources.SortByDistance({ unpack(entries) }, map, px, py)
		end
		for _, e in ipairs(entries) do
			local text, stat = Format.Entry(group, e)
			add(f.rowH, function(page)
				local spec = { text = text, right = stat, icon = KIND_ICON[group.key], indent = 6 }
				if group.key == "c" then
					spec.icon = ItemIcon(e.id)
					spec.item = e.id
					spec.onClick = function()
						Pages.GoItem(e.id)
					end
				elseif e.locations or e.m then
					spec.onClick = function()
						if ns.Waypoint.ToEntry(e) then
							Pages.Toast(page, "A waypoint is set.")
						else
							Pages.Toast(page, "That one is inside an instance.")
						end
					end
					spec.tooltip = function(tip)
						tip:AddLine(e.name or "?", 1, 0.82, 0)
						for _, loc in ipairs(e.locations or {}) do
							local where = loc.instance and Format.names.instance(loc.instance) or Format.names.zone(loc.map)
							tip:AddDoubleLine(where, loc.count .. (loc.count == 1 and " spawn" or " spawns"), 1, 1, 1, 0.7, 0.7, 0.7)
						end
						tip:AddLine("Click: waypoint to the nearest one", 0.5, 0.5, 0.5)
					end
				end
				Row(page, spec)
			end)
		end
	end
	if craft.teaches then
		local r = craft.teaches
		add(f.rowH + 6, function(page)
			Space(page, 4)
			Text(page, "Teaches", f.heading, Book.INK, { wrap = false, after = 2 })
		end, true)
		add(f.rowH, function(page)
			Row(page, { text = Format.names.spell(r.spell), right = Format.names.profession(r.skill) .. " " .. r.orange,
				icon = RecipeIcon(r), indent = 6, color = ns.Knows(r.spell) and { 0.08, 0.40, 0.06 } or nil,
				onClick = function()
					Pages.GoRecipe(r.spell)
				end })
		end)
	end
	for title, list in pairs({ ["Crafted with"] = craft.createdBy }) do
		if #list > 0 then
			add(f.rowH + 6, function(page)
				Space(page, 4)
				Text(page, title, f.heading, Book.INK, { wrap = false, after = 2 })
			end, true)
			for _, r in ipairs(list) do
				add(f.rowH, function(page)
					Row(page, { text = Format.names.spell(r.spell), right = Format.names.profession(r.skill) .. " " .. r.orange,
						icon = RecipeIcon(r), indent = 6, onClick = function()
							Pages.GoRecipe(r.spell)
						end })
				end)
			end
		end
	end
	if #craft.usedIn > 0 then
		add(f.rowH + 6, function(page)
			Space(page, 4)
			Text(page, "Reagent for " .. #craft.usedIn .. (#craft.usedIn == 1 and " recipe" or " recipes"), f.heading, Book.INK,
				{ wrap = false, after = 2 })
		end, true)
		for _, r in ipairs(craft.usedIn) do
			add(f.rowH, function(page)
				Row(page, { text = Format.names.spell(r.spell), right = Format.names.profession(r.skill) .. " " .. r.orange,
					icon = r.item > 0 and ItemIcon(r.item) or SpellIcon(r.spell), indent = 6,
					color = r.item > 0 and QualityInk(r.item) or nil, onClick = function()
						Pages.GoRecipe(r.spell)
					end })
			end)
		end
	end
	return els, info, craft
end

local function ItemSpread(state)
	return function(buffer)
		local f = Fonts()
		local left, right = buffer.left, buffer.right
		Begin(left)
		Begin(right)
		local id = state.id
		local els, info, craft = ItemElements(id)
		SpreadNav(left, right)
		local top = left.navTop
		-- The first page of an entry starts with the header and the summary.
		local headerH = 0
		if state.sub == 1 then
			Header(left, ItemIcon(id), Format.names.item(id), QualityInk(id), TypeLine(id))
			local have = Have(id)
			if have > 0 then
				Text(left, "You carry " .. have .. ".", f.small, { 0.08, 0.40, 0.06 }, { after = 4 })
			end
			Text(left, Summary(info, craft), f.body, Book.INK_SOFT, { after = 6 })
			Rule(left)
			headerH = left.cursor - top
		end
		-- Flow: page 1 is the left page under the header, then right, then the next spreads.
		local heights, keep = {}, {}
		for i, e in ipairs(els) do
			heights[i] = e.h
			keep[i] = e.keep
		end
		local cap = left.h - top - FooterHeight()
		-- The flow is worked out on the first spread (where the header's height is known) and
		-- kept, so continued spreads pick up exactly where the last one stopped.
		local pageOf, pages = state.flow, state.flowPages
		if state.sub == 1 or not pageOf then
			table.insert(heights, 1, headerH)
			table.insert(keep, 1, false)
			pageOf, pages = Library.Flow(heights, cap, keep)
			state.flow, state.flowPages = pageOf, pages
		end
		local spreads = math.max(1, math.ceil(pages / 2))
		state.spreads = spreads
		local first = (state.sub - 1) * 2 + 1
		for i, e in ipairs(els) do
			local p = pageOf[i + 1]
			if p == first then
				e.draw(left)
			elseif p == first + 1 then
				e.draw(right)
			end
		end
		Footers(left, right, state.sub, spreads)
	end
end

local function RecipeSpread(state)
	return function(buffer)
		local f = Fonts()
		local left, right = buffer.left, buffer.right
		Begin(left)
		Begin(right)
		SpreadNav(left, right)
		Footers(left, right, 1, 1)
		local r = ns.Codec.Recipe(state.id)
		if not r then
			Text(left, "This recipe isn't in the book.", f.body)
			return
		end
		local icon = r.item > 0 and ItemIcon(r.item) or SpellIcon(r.spell)
		Header(left, icon, Format.names.spell(r.spell), r.item > 0 and QualityInk(r.item) or Book.INK,
			string.format("%s  |cffc05010%d|r  |cffa08000%d|r  |cff307030%d|r", Format.names.profession(r.skill), r.orange, r.yellow, r.gray))
		if ns.Knows(r.spell) then
			Text(left, "You know this recipe.", f.small, { 0.08, 0.40, 0.06 }, { after = 4 })
		end
		if r.item > 0 then
			Row(left, { text = "Makes " .. Format.names.item(r.item), right = r.count > 1 and (r.count .. "x") or "",
				icon = ItemIcon(r.item), color = QualityInk(r.item), item = r.item, onClick = function()
					Pages.GoItem(r.item)
				end })
		end
		if r.learnedFrom > 0 then
			Row(left, { text = "Learned from " .. Format.names.item(r.learnedFrom), right = "where?", icon = ItemIcon(r.learnedFrom),
				color = QualityInk(r.learnedFrom), item = r.learnedFrom, onClick = function()
					Pages.GoItem(r.learnedFrom)
				end })
		else
			Text(left, "Taught by a trainer.", f.small, Book.INK_SOFT, { after = 4 })
		end
		Rule(left)
		Text(left, "Reagents", f.heading, Book.INK, { wrap = false, after = 2 })
		for _, reagent in ipairs(r.reagents) do
			local have = Have(reagent.item)
			local enough = have >= reagent.count
			Row(left, { text = Format.names.item(reagent.item), icon = ItemIcon(reagent.item), color = QualityInk(reagent.item),
				right = (enough and "|cff156b0b" or "|cff8b1a0a") .. have .. " / " .. reagent.count .. "|r", item = reagent.item,
				indent = 6, onClick = function()
					Pages.GoItem(reagent.item)
				end })
		end
		-- Right page: the plan.
		local times = state.times or 1
		Text(right, "Crafting it " .. times .. (times == 1 and " time" or " times"), f.heading, Book.INK, { wrap = false, after = 2 })
		Links(right, {
			{ text = "one more", onClick = function()
				state.times = times + 1
				Pages.RewriteRight()
			end },
			{ text = "ten more", onClick = function()
				state.times = times + 10
				Pages.RewriteRight()
			end },
			times > 1 and { text = "back to one", onClick = function()
				state.times = 1
				Pages.RewriteRight()
			end } or { text = "" },
		})
		Rule(right)
		local plan = ns.Craft.Plan(r.spell, times, Have)
		if #plan.steps > 1 then
			Text(right, "Craft, in this order", f.heading, Book.INK, { wrap = false, after = 2 })
			for _, step in ipairs(plan.steps) do
				if Remaining(right) < f.rowH + FooterHeight() then
					break
				end
				Row(right, { text = Format.names.spell(step.spell), right = step.crafts .. "x", icon = RecipeIcon(ns.Codec.Recipe(step.spell)), indent = 6,
					onClick = step.spell ~= r.spell and function()
						Pages.GoRecipe(step.spell)
					end or nil })
			end
			Space(right, 6)
		end
		local missing = false
		for _, line in ipairs(plan.raw) do
			if line.missing > 0 then
				if not missing then
					Text(right, "Still to gather", f.heading, Book.INK, { wrap = false, after = 2 })
					missing = true
				end
				if Remaining(right) > f.rowH * 1.2 + FooterHeight() then
					Row(right, { text = Format.names.item(line.item), icon = ItemIcon(line.item), color = QualityInk(line.item),
						right = string.format("|cff8b1a0a%d more|r", line.missing), item = line.item, indent = 6, onClick = function()
							Pages.GoItem(line.item)
						end })
				end
			end
		end
		if not missing then
			Text(right, "You have everything it needs.", f.body, { 0.08, 0.40, 0.06 })
		end
	end
end

local BUILDERS = { index = IndexSpread, item = ItemSpread, recipe = RecipeSpread }

local function Builder(state)
	return BUILDERS[state.kind](state)
end

-- ---------------------------------------------------------------- search box

-- One edit box per page buffer, written into the index's left page.
function Pages.SearchBox(page, state)
	local f = Fonts()
	if not page.search then
		local e = CreateFrame("EditBox", nil, page)
		e:SetAutoFocus(false)
		e:SetFontObject(f.body)
		e:SetTextColor(Book.INK[1], Book.INK[2], Book.INK[3])
		e:SetTextInsets(22, 4, 0, 0)
		local glass = e:CreateTexture(nil, "ARTWORK")
		glass:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
		glass:SetVertexColor(0.35, 0.22, 0.1)
		glass:SetSize(14, 14)
		glass:SetPoint("LEFT", 2, 0)
		e.line = e:CreateTexture(nil, "ARTWORK")
		e.line:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\rule.png")
		e.line:SetPoint("BOTTOMLEFT", 0, -2)
		e.line:SetPoint("BOTTOMRIGHT", 0, -2)
		e.line:SetHeight(8)
		e.hint = e:CreateFontString(nil, "ARTWORK")
		e.hint:SetFontObject(f.small)
		e.hint:SetTextColor(Book.INK_SOFT[1], Book.INK_SOFT[2], Book.INK_SOFT[3], 0.8)
		e.hint:SetPoint("LEFT", 22, 0)
		e.hint:SetText("Seek an item by name...")
		-- Escape clears the search first, then lets go of the box.
		e:SetScript("OnEscapePressed", function(self)
			if self:GetText() ~= "" then
				self:SetText("")
				local cur = nav.current
				if cur and cur.kind == "index" then
					cur.query, cur.page = "", 1
					Pages.Refresh(true)
				end
			else
				self:ClearFocus()
			end
		end)
		-- Enter opens the best match.
		e:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
			local cur = nav.current
			if cur and cur.kind == "index" and (cur.query or "") ~= "" then
				local list = Pages.Browse(cur.query, cur.category, cur.sort)
				if list[1] then
					Pages.GoItem(list[1])
				end
			end
		end)
		e:SetScript("OnTextChanged", function(self, user)
			self.hint:SetShown(self:GetText() == "")
			local cur = nav.current
			if not user or not cur or cur.kind ~= "index" then
				return
			end
			cur.query = self:GetText()
			cur.page = 1
			if searchTimer then
				searchTimer:Cancel()
			end
			searchTimer = C_Timer.NewTimer(0.22, function()
				searchTimer = nil
				Pages.Refresh(true)
			end)
		end)
		page.search = e
	end
	local e = page.search
	e:ClearAllPoints()
	e:SetPoint("TOPLEFT", page, "TOPLEFT", page.x + page.w * 0.05, -(page.y + page.cursor))
	e:SetSize(page.w * 0.9, f.rowH)
	if e:GetText() ~= (state.query or "") then
		e:SetText(state.query or "")
	end
	e.hint:SetShown(e:GetText() == "")
	e:Show()
	page.cursor = page.cursor + f.rowH + 10
	page.inkOthers[#page.inkOthers + 1] = e
end

-- ---------------------------------------------------------------- navigation

-- The last search, kept so leafing through the index doesn't re-sort 7,000 names per turn.
local browseKey, browseList
function Pages.Browse(query, category, sort)
	local key = (query or "") .. "|" .. (category or "") .. "|" .. (sort or "")
	if key ~= browseKey then
		browseKey, browseList = key, Library.Browse(query, category, sort)
	end
	return browseList
end

local function Copy(state)
	local c = {}
	for k, v in pairs(state) do
		c[k] = v
	end
	return c
end

-- Shows a state: a page turn when the book is open (dir 1 forward, -1 back), else opens onto it.
local function Show(state, dir)
	if Book.IsOpen() then
		Book.Turn(dir or 1, Builder(state))
	else
		Book.Open(Builder(state))
		Pages.InstallInput()
	end
end

function Pages.Index()
	return { kind = "index", query = "", category = "all", sort = "name", page = 1 }
end

function Pages.Current()
	return nav.current
end

-- Somewhere new: history grows, forward is cleared. Going where you already are does nothing.
function Pages.Go(state)
	-- Opening straight onto an item: put the index underneath, so Back always has somewhere to go.
	if not nav.current and state.kind ~= "index" then
		nav:Go(Pages.Index())
	end
	if nav:Go(state) then
		Show(state, 1)
	elseif not Book.IsOpen() then
		Show(nav.current, 1)
	end
end

function Pages.GoItem(id)
	Pages.Go({ kind = "item", id = id, sub = 1 })
end

function Pages.GoRecipe(spell)
	Pages.Go({ kind = "recipe", id = spell, times = 1 })
end

-- Back to the index: your last search and page, turning backward like flipping to the front.
function Pages.GoIndex()
	local cur = nav.current
	if cur and cur.kind == "index" then
		return
	end
	local last = nav:LastIndex()
	local state = last and Copy(last) or Pages.Index()
	nav:Go(state)
	Show(state, -1)
end

function Pages.GoBack()
	local prev = nav:Back()
	if prev then
		Show(prev, -1)
	end
end

function Pages.GoForward()
	local nxt = nav:Forward()
	if nxt then
		Show(nxt, 1)
	end
end

-- Clicking a breadcrumb: jump straight back to it in one turn.
function Pages.GoCrumb(steps)
	if steps <= 0 then
		return
	end
	local target = nav:BackSteps(steps)
	if target then
		Show(target, -1)
	end
end

-- Paging inside a view (the index's pages, a long entry's spreads) moves through the book
-- without adding history: Back leaves the whole view.
local function Pageable()
	local cur = nav.current
	if not cur then
		return nil
	end
	if cur.kind == "index" then
		return cur.page or 1, cur.pages or 1
	elseif cur.kind == "item" then
		return cur.sub or 1, cur.spreads or 1
	end
	return nil
end

function Pages.TurnPage(dir)
	local cur = nav.current
	local at, total = Pageable()
	if not at or at + dir < 1 or at + dir > total then
		return false
	end
	if cur.kind == "index" then
		cur.page = at + dir
	else
		cur.sub = at + dir
	end
	Book.Turn(dir, Builder(cur))
	return true
end

-- Kept for older callers.
function Pages.TurnIndex(dir)
	return Pages.TurnPage(dir)
end

function Pages.TurnSub(dir)
	return Pages.TurnPage(dir)
end

-- Rewrite the current spread in place (filters, typing, plan counts).
function Pages.Refresh(keepFocus)
	local cur = nav.current
	if not cur or not Book.IsOpen() or Book.IsBusy() then
		return
	end
	-- While typing, only the results are rewritten; the title, box and filters stay put.
	Book.Rewrite(Builder(cur), nil, keepFocus and cur.kind == "index")
end

function Pages.RewriteRight()
	local cur = nav.current
	if cur and not Book.IsBusy() then
		Book.Rewrite(Builder(cur), { "right" })
	end
end

-- A short line of ink at the bottom of a page that fades on its own.
function Pages.Toast(page, text)
	local f = Fonts()
	if not page.toast then
		page.toast = page:CreateFontString(nil, "OVERLAY")
		page.toast:SetFontObject(f.small)
		page.toast:SetTextColor(0.55, 0.25, 0.05)
	end
	local t = page.toast
	t:ClearAllPoints()
	t:SetPoint("BOTTOM", page, "BOTTOM", 0, page:GetHeight() * INSET_BOTTOM + f.rowH * 1.2)
	t:SetText(text)
	t:Show()
	t:SetAlpha(1)
	t.token = (t.token or 0) + 1
	local token = t.token
	C_Timer.After(1.8, function()
		if t.token == token then
			t:SetAlpha(0)
		end
	end)
end

-- ---------------------------------------------------------------- input

-- The mouse wheel leafs through pages.
function Pages.OnWheel(delta)
	if not Book.IsBusy() then
		Pages.TurnPage(delta < 0 and 1 or -1)
	end
end

-- Right-click anywhere on the book, or mouse button 4, goes back; button 5 goes forward.
function Pages.Mouse(button)
	if button == "RightButton" or button == "Button4" then
		Pages.GoBack()
	elseif button == "Button5" then
		Pages.GoForward()
	end
end

local function FocusSearch()
	local b = Book.Buffer("shown")
	local box = b and b.left and b.left.search
	if box and box:IsShown() then
		box:SetFocus()
		box:HighlightText()
		return true
	end
	return false
end

local wantFocus = false

-- Keys while the book is open. Returns true when the key was used (it then doesn't reach the
-- game); everything else, movement included, passes straight through.
function Pages.Key(key)
	if key == "BACKSPACE" then
		Pages.GoBack()
		return true
	elseif key == "LEFT" or key == "PAGEUP" then
		if not Pages.TurnPage(-1) and key == "LEFT" then
			Pages.GoBack()
		end
		return true
	elseif key == "RIGHT" or key == "PAGEDOWN" then
		if not Pages.TurnPage(1) and key == "RIGHT" then
			Pages.GoForward()
		end
		return true
	elseif key == "HOME" then
		Pages.GoIndex()
		return true
	elseif key == "F" and IsControlKeyDown() then
		local cur = nav.current
		if cur and cur.kind == "index" and not Book.IsBusy() then
			FocusSearch()
		else
			wantFocus = true
			Pages.GoIndex()
		end
		return true
	end
	return false
end

local inputInstalled = false

function Pages.InstallInput()
	if inputInstalled then
		return
	end
	local root = Book.Root()
	if not root then
		return
	end
	inputInstalled = true
	local function Propagate(on)
		pcall(root.SetPropagateKeyboardInput, root, on)
	end
	-- Opened mid-fight: leave the keyboard alone until combat ends (the regen handler enables it).
	if not InCombatLockdown() then
		root:EnableKeyboard(true)
		Propagate(true)
	end
	root:SetScript("OnKeyDown", function(_, key)
		if InCombatLockdown() then
			return
		end
		local used = false
		if Book.IsOpen() then
			used = Pages.Key(key)
		end
		Propagate(not used)
	end)
	root:SetScript("OnKeyUp", function()
		if not InCombatLockdown() then
			Propagate(true)
		end
	end)
	root:SetScript("OnMouseUp", function(_, button)
		Pages.Mouse(button)
	end)
	-- In combat the keyboard is left entirely to the game.
	local combat = CreateFrame("Frame")
	combat:RegisterEvent("PLAYER_REGEN_DISABLED")
	combat:RegisterEvent("PLAYER_REGEN_ENABLED")
	combat:SetScript("OnEvent", function(_, event)
		if event == "PLAYER_REGEN_DISABLED" then
			Propagate(true)
			pcall(root.EnableKeyboard, root, false)
		else
			pcall(root.EnableKeyboard, root, true)
			Propagate(true)
		end
	end)
end

-- Item names and icons arrive from the server a moment after first use: redraw quietly (no ink
-- animation) once they have, a few at a time.
local infoPending = false
function Pages.OnItemInfo()
	if infoPending or not Book.IsOpen() then
		return
	end
	infoPending = true
	C_Timer.After(0.3, function()
		infoPending = false
		local cur = nav.current
		if cur and Book.IsOpen() and not Book.IsBusy() then
			Book.Rewrite(Builder(cur), {})
		end
	end)
end

function Pages.OnSettled()
	if wantFocus then
		wantFocus = false
		FocusSearch()
	end
end

-- The book broke: show the same thing in the plain window.
function Pages.OnFail()
	local cur = nav.current
	if not cur then
		return
	end
	if cur.kind == "item" then
		ns.Panel.ShowItem(cur.id)
	elseif cur.kind == "recipe" then
		ns.Panel.ShowRecipe(cur.id)
	else
		ns.Panel.ShowSearch(cur.query or "")
	end
end

function Pages.OnClose()
	wantFocus = false
	for _, which in ipairs({ "shown", "hidden" }) do
		local b = Book.Buffer(which)
		if b and b.left and b.left.search then
			b.left.search:ClearFocus()
		end
	end
end

-- ---------------------------------------------------------------- entry points
-- History lives for the whole session: closing and reopening the book keeps your trail, and
-- the book reopens where you left it.

function Pages.Open(state)
	if state then
		Pages.Go(state)
		return
	end
	if Book.IsOpen() then
		return
	end
	if not nav.current then
		nav:Go(Pages.Index())
	end
	Show(nav.current, 1)
end

function Pages.ShowItem(id)
	Pages.Go({ kind = "item", id = id, sub = 1 })
end

function Pages.ShowRecipe(spell)
	Pages.Go({ kind = "recipe", id = spell, times = 1 })
end

function Pages.ShowSearch(text)
	local state = Pages.Index()
	state.query = text or ""
	Pages.Go(state)
end

function Pages.Toggle()
	if Book.IsOpen() then
		Book.Close()
	else
		Pages.Open()
	end
end
