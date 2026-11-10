-- Sourcebook: the book. A rendered leather tome that opens in the middle of the screen; every
-- view is a spread of two parchment pages, and moving between views turns a real (pre-rendered)
-- page while the ink fades out and writes itself back in.
--
-- Layers, bottom to top: backdrop (vignette + candle glow) | spread | page content | turning
-- sheet | cover | sparkles. Page content is double-buffered: the next spread is built in the
-- hidden buffer while the current one is still on screen.

local ADDON, ns = ...

local Book = {}
ns.Book = Book

local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
local Art -- ns.BookArt, set on first use

-- Timing (seconds).
local OPEN_DROP = 0.35
local OPEN_SWING = 1.05
local TURN = 0.88
local SHEET_FADE = 0.12
local WRITE = 0.55
local LINE_STAGGER = 0.025
local CROSSFADE = false -- frames are far apart mid-turn: blending shows two pages. Motion blur is baked in.

local INK = { 0.20, 0.11, 0.05 }
local INK_SOFT = { 0.36, 0.24, 0.13 }
local QUALITY_INK = {
	[0] = { 0.38, 0.36, 0.33 },
	[1] = { 0.20, 0.11, 0.05 },
	[2] = { 0.08, 0.40, 0.06 },
	[3] = { 0.02, 0.26, 0.56 },
	[4] = { 0.42, 0.10, 0.58 },
	[5] = { 0.70, 0.36, 0.00 },
}
Book.INK, Book.INK_SOFT, Book.QUALITY_INK = INK, INK_SOFT, QUALITY_INK

local root, backdrop, spreadTex, sheetA, sheetB, shadowA, shadowB, sheetLayer, coverLayer, fxLayer, escProxy
local coverStrips, backStrips, runeStrips, coverShadow, pageGlow, runesTex, glintTex, glintMask
local runeLevel = 0.6 -- rune glow strength, pulsed by the opening
local buffers = {} -- [1], [2] = { left = frame, right = frame, pool = {...} }
local shown = 1 -- buffer on screen
local busy = false
local queued
local W, H = 1, 1
local state = "closed"

-- ---------------------------------------------------------------- tweens

local tweens = {}
local driver = CreateFrame("Frame")

local function Tween(duration, fn, done, delay)
	local t = { d = math.max(duration, 0.0001), fn = fn, done = done, t = -(delay or 0) }
	tweens[#tweens + 1] = t
	return t
end

local function Ease(p)
	return p < 0.5 and 4 * p * p * p or 1 - (-2 * p + 2) ^ 3 / 2
end

local function EaseOut(p)
	return 1 - (1 - p) ^ 3
end

local particles = {}
local ambientClock = 0

local Fail, Reset, CancelAll -- defined further down

driver:SetScript("OnUpdate", function(_, elapsed)
	if elapsed > 0.1 then
		elapsed = 0.1
	end
	for i = #tweens, 1, -1 do
		local t = tweens[i]
		if t then
			t.t = t.t + elapsed
			if t.t >= 0 then
				local p = math.min(1, t.t / t.d)
				local good, err = pcall(t.fn, p)
				if good and p >= 1 then
					for j = #tweens, 1, -1 do
						if tweens[j] == t then
							table.remove(tweens, j)
						end
					end
					if t.done then
						good, err = pcall(t.done)
					end
				end
				if not good then
					Fail(err)
					return
				end
			end
		end
	end
	Book.UpdateParticles(elapsed)
	if state == "open" and root and root:IsShown() then
		ambientClock = ambientClock + elapsed
		Book.Ambient(elapsed)
	end
end)

-- ---------------------------------------------------------------- geometry

-- Book-space rect (fractions of the spread image) -> offsets inside root.
local function Rect(r)
	return r[1] * W, -r[2] * H, (r[3] - r[1]) * W, (r[4] - r[2]) * H
end

local function Place(region, r, inset)
	local x, y, w, h = Rect(r)
	inset = inset or 0
	region:ClearAllPoints()
	region:SetPoint("TOPLEFT", root, "TOPLEFT", x + inset, y - inset)
	region:SetSize(w - 2 * inset, h - 2 * inset)
end

function Book.PageRect(side)
	return Art[side]
end

function Book.Size()
	return W, H
end

-- ---------------------------------------------------------------- particles

local pool = {}

local function Particle(kind)
	local p = table.remove(pool)
	if not p then
		p = { tex = fxLayer:CreateTexture(nil, "OVERLAY") }
		p.tex:SetBlendMode("ADD")
	end
	p.tex:SetTexture(MEDIA .. (kind == "spark" and "sparkle.png" or "mote.png"))
	p.tex:Show()
	particles[#particles + 1] = p
	return p
end

-- x, y in root coordinates (0..W, 0..-H). opts: count, spread, vx, vy, size, life, color, kind, gravity
function Book.Burst(x, y, opts)
	if not fxLayer then
		return
	end
	for _ = 1, opts.count or 10 do
		local p = Particle(opts.kind or "spark")
		local a = math.random() * 2 * math.pi
		local s = (opts.speed or 40) * (0.4 + math.random() * 0.8)
		p.x = x + (math.random() - 0.5) * (opts.spreadX or opts.spread or 10)
		p.y = y + (math.random() - 0.5) * (opts.spreadY or opts.spread or 10)
		p.vx = (opts.vx or 0) + math.cos(a) * s
		p.vy = (opts.vy or 0) + math.sin(a) * s
		p.g = opts.gravity or -8
		p.age = -(math.random() * (opts.jitter or 0))
		p.life = (opts.life or 1.2) * (0.6 + math.random() * 0.8)
		p.size = (opts.size or 14) * (0.5 + math.random())
		p.peak = opts.alpha or 0.9
		local c = opts.color or { 1, 0.82, 0.45 }
		p.tex:SetVertexColor(c[1], c[2], c[3])
		p.twinkle = opts.kind == "spark" and (3 + math.random() * 6) or 0
	end
end

function Book.UpdateParticles(dt)
	for i = #particles, 1, -1 do
		local p = particles[i]
		p.age = p.age + dt
		if p.age >= p.life then
			p.tex:Hide()
			pool[#pool + 1] = table.remove(particles, i)
		elseif p.age >= 0 then
			p.vy = p.vy - p.g * dt
			p.x = p.x + p.vx * dt
			p.y = p.y + p.vy * dt
			p.vx = p.vx * (1 - 0.6 * dt)
			local k = p.age / p.life
			local a = p.peak * math.sin(math.pi * k) ^ 0.7
			if p.twinkle > 0 then
				a = a * (0.65 + 0.35 * math.sin(p.age * p.twinkle * 6.28))
			end
			local s = p.size * (1 - 0.4 * k)
			p.tex:ClearAllPoints()
			p.tex:SetPoint("CENTER", root, "TOPLEFT", p.x, p.y)
			p.tex:SetSize(s, s)
			p.tex:SetAlpha(a)
		else
			p.tex:SetAlpha(0)
		end
	end
end

-- Dust motes drifting through the candle light, and the candle's flicker.
local nextMote = 0
function Book.Ambient(dt)
	nextMote = nextMote - dt
	if nextMote <= 0 then
		nextMote = 0.35 + math.random() * 0.5
		Book.Burst(math.random() * W, -H * (0.15 + math.random() * 0.8), {
			count = 1, kind = "mote", speed = 4, vy = 3, gravity = -1, life = 7, size = 5, alpha = 0.35,
			color = { 1, 0.85, 0.6 }, spread = 0,
		})
	end
	if backdrop and backdrop.candle then
		local f = 0.30 + 0.035 * math.sin(ambientClock * 7.3) + 0.025 * math.sin(ambientClock * 13.1 + 1.2)
			+ 0.02 * math.sin(ambientClock * 2.1)
		backdrop.candle:SetAlpha(f)
	end
	if runesTex and runesTex:IsShown() then
		runesTex:SetAlpha(0.55 + 0.25 * math.sin(ambientClock * 2.2))
	end
end

-- ---------------------------------------------------------------- the frames

local function Build()
	Art = ns.BookArt
	local uiH, uiW = UIParent:GetHeight(), UIParent:GetWidth()
	H = uiH * 0.88
	W = H * Art.spread.w / Art.spread.h
	if W > uiW * 0.96 then
		W = uiW * 0.96
		H = W * Art.spread.h / Art.spread.w
	end

	backdrop = CreateFrame("Button", "SourcebookBookBackdrop", UIParent)
	backdrop:SetAllPoints(UIParent)
	backdrop:SetFrameStrata("DIALOG")
	backdrop:SetFrameLevel(1)
	backdrop:RegisterForClicks("AnyUp")
	backdrop:SetScript("OnClick", function(_, button)
		-- Mouse 4 and 5 are back and forward, even outside the book; any other click closes it.
		if (button == "Button4" or button == "Button5") and ns.BookPages and ns.BookPages.Mouse then
			ns.BookPages.Mouse(button)
		else
			Book.Close()
		end
	end)
	local vig = backdrop:CreateTexture(nil, "BACKGROUND")
	vig:SetAllPoints()
	vig:SetTexture(MEDIA .. "vignette.png")
	local candle = backdrop:CreateTexture(nil, "ARTWORK")
	candle:SetTexture(MEDIA .. "glow.png")
	candle:SetBlendMode("ADD")
	candle:SetVertexColor(1, 0.66, 0.32)
	candle:SetSize(W * 1.6, H * 1.7)
	candle:SetPoint("CENTER", UIParent, "CENTER", -W * 0.12, H * 0.06)
	backdrop.candle = candle
	backdrop:Hide()

	root = CreateFrame("Frame", "SourcebookBook", UIParent)
	root:SetSize(W, H)
	root:SetPoint("CENTER", 0, -uiH * 0.01)
	root:SetFrameStrata("DIALOG")
	root:SetFrameLevel(10)
	root:EnableMouse(true)
	root:EnableMouseWheel(true)
	root:SetScript("OnMouseWheel", function(_, delta)
		if state == "open" and ns.BookPages and ns.BookPages.OnWheel then
			ns.BookPages.OnWheel(delta)
		end
	end)
	root:Hide()

	spreadTex = root:CreateTexture(nil, "ARTWORK")
	spreadTex:SetTexture(MEDIA .. "spread.png")
	spreadTex:SetAllPoints()
	spreadTex:SetTexCoord(0, Art.spread.w / Art.spread.tw, 0, Art.spread.h / Art.spread.th)

	-- Light spilling out of the uncovered page: an even warm wash over the page (a radial
	-- glow read as a bright blotch on the parchment).
	pageGlow = root:CreateTexture(nil, "OVERLAY")
	pageGlow:SetColorTexture(1, 1, 1, 1)
	pageGlow:SetBlendMode("ADD")
	pageGlow:SetVertexColor(1, 0.78, 0.42)
	pageGlow:SetAlpha(0)

	-- The standing cover's shadow: a band falling from the spine, darkest at the spine.
	coverShadow = root:CreateTexture(nil, "OVERLAY", nil, 1)
	coverShadow:SetColorTexture(1, 1, 1, 1)
	if CreateColor then
		pcall(coverShadow.SetGradient, coverShadow, "HORIZONTAL", CreateColor(0, 0, 0, 1), CreateColor(0, 0, 0, 0))
	end
	coverShadow:SetAlpha(0)

	for i = 1, 2 do
		local b = { pool = {} }
		for _, side in ipairs({ "left", "right" }) do
			local f = CreateFrame("Frame", nil, root)
			f:SetFrameLevel(root:GetFrameLevel() + 3)
			Place(f, Art[side])
			f:Hide()
			b[side] = f
		end
		buffers[i] = b
	end

	sheetLayer = CreateFrame("Frame", nil, root)
	sheetLayer:SetFrameLevel(root:GetFrameLevel() + 12)
	sheetLayer:SetSize(W * Art.overscan, H * Art.overscan)
	sheetLayer:SetPoint("CENTER", root, "CENTER")
	-- The shadow sits under the sheet but over the page text, so ink darkens in it too.
	shadowA = sheetLayer:CreateTexture(nil, "BORDER")
	shadowB = sheetLayer:CreateTexture(nil, "BORDER", nil, 1)
	sheetA = sheetLayer:CreateTexture(nil, "ARTWORK")
	sheetB = sheetLayer:CreateTexture(nil, "ARTWORK", nil, 1)
	for _, t in ipairs({ shadowA, shadowB, sheetA, sheetB }) do
		t:Hide()
	end

	coverLayer = CreateFrame("Frame", nil, root)
	coverLayer:SetFrameLevel(root:GetFrameLevel() + 16)
	coverLayer:SetAllPoints()
	coverStrips, backStrips, runeStrips = {}, {}, {}
	for i = 1, 16 do
		local front = coverLayer:CreateTexture(nil, "ARTWORK")
		front:SetTexture(MEDIA .. "cover.png")
		coverStrips[i] = front
		local back = coverLayer:CreateTexture(nil, "ARTWORK")
		back:SetTexture(MEDIA .. "spread.png")
		backStrips[i] = back
		-- The runes' glow rides the cover strip by strip, in perspective with it.
		local rune = coverLayer:CreateTexture(nil, "OVERLAY")
		rune:SetTexture(MEDIA .. "cover_runes.png")
		rune:SetBlendMode("ADD")
		runeStrips[i] = rune
	end
	runesTex = coverLayer:CreateTexture(nil, "OVERLAY")
	runesTex:SetTexture(MEDIA .. "cover_runes.png")
	runesTex:SetBlendMode("ADD")
	glintTex = coverLayer:CreateTexture(nil, "OVERLAY", nil, 1)
	glintTex:SetTexture(MEDIA .. "cover_glint.png")
	glintTex:SetBlendMode("ADD")
	local good = pcall(function()
		glintMask = coverLayer:CreateMaskTexture()
		glintMask:SetTexture(MEDIA .. "sweep.png", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		glintTex:AddMaskTexture(glintMask)
	end)
	if not good then
		glintMask = nil
		glintTex:SetAlpha(0) -- no masks: skip the glint rather than flash the whole tooling
	end

	-- Every turn atlas, drawn tiny and nearly invisible while the book is open, so the first turn
	-- doesn't wait on a 2048px texture loading mid-flip.
	for k = 1, Art.atlases do
		local pre = root:CreateTexture(nil, "BACKGROUND")
		pre:SetTexture(MEDIA .. "turn" .. k .. ".png")
		pre:SetSize(1, 1)
		pre:SetPoint("TOPLEFT")
		pre:SetAlpha(0.01)
	end
	for k = 1, Art.shadowAtlases or 0 do
		local pre = root:CreateTexture(nil, "BACKGROUND")
		pre:SetTexture(MEDIA .. "shadow" .. k .. ".png")
		pre:SetSize(1, 1)
		pre:SetPoint("TOPLEFT")
		pre:SetAlpha(0.01)
	end

	fxLayer = CreateFrame("Frame", nil, root)
	fxLayer:SetFrameLevel(root:GetFrameLevel() + 30)
	fxLayer:SetAllPoints()

	-- Ribbons and corner guards are clickable: red ribbon = index, gold ribbon = back,
	-- top-right gold corner = close.
	Book.MakeHotspots()

	-- Escape closes with the animation: a stand-in frame sits in UISpecialFrames.
	escProxy = CreateFrame("Frame", "SourcebookBookEsc", UIParent)
	escProxy:Hide()
	escProxy:SetScript("OnHide", function()
		if state == "open" or state == "opening" then
			Book.Close()
		end
	end)
	tinsert(UISpecialFrames, "SourcebookBookEsc")
	Book.built = true
end

function Book.Root()
	return root
end

function Book.MakeHotspots()
	local bx0, by0, bx1, by1 = Art.book[1], Art.book[2], Art.book[3], Art.book[4]
	local gutter = (Art.left[3] + Art.right[1]) / 2
	local function Hot(x0, y0, x1, y1, title, text, onClick)
		local b = CreateFrame("Button", nil, root)
		b:SetFrameLevel(root:GetFrameLevel() + 20)
		Place(b, { x0, y0, x1, y1 })
		b:SetScript("OnClick", onClick)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(title, 1, 0.82, 0)
			if text then
				GameTooltip:AddLine(text, 1, 1, 1, true)
			end
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		return b
	end
	-- Ribbons hang below the gutter: red slightly right of it, gold slightly left.
	Hot(gutter - 0.004, by1 - 0.01, gutter + 0.03, math.min(0.999, by1 + 0.11), "Index", "The index of every item. (Home)", function()
		ns.BookPages.GoIndex()
	end)
	Hot(gutter - 0.03, by1 - 0.01, gutter - 0.004, math.min(0.999, by1 + 0.09), "Back", "Turn back to where you were. (Backspace, right-click, or mouse button 4)", function()
		ns.BookPages.GoBack()
	end)
	local cw = 0.05
	Hot(bx1 - cw, by0, bx1, by0 + cw * W / H, "Close the book", "(Escape, or click outside the book)", function()
		Book.Close()
	end)
end

-- ---------------------------------------------------------------- content buffers

function Book.Buffer(which)
	return buffers[which == "hidden" and (3 - shown) or shown]
end

local function SetContentAlpha(buffer, side, a)
	buffer[side]:SetAlpha(a)
end

-- Hands every FontString in a page an alpha-gradient write-in, top to bottom. With from set,
-- only strings and regions from that index on are animated; the rest are shown as they are.
local function ShowAll(page)
	for _, fs in ipairs(page.inkStrings or {}) do
		fs.inkToken = (fs.inkToken or 0) + 1
		fs:SetAlphaGradient(#(fs:GetText() or "") + 24, 1)
		fs:SetAlpha(1)
	end
	for _, region in ipairs(page.inkOthers or {}) do
		region:SetAlpha(1)
	end
	page:Show()
	page:SetAlpha(1)
end
Book.ShowAll = ShowAll

local function WriteIn(page, duration, delay, from, othersFrom)
	local strings = page.inkStrings or {}
	local others = page.inkOthers or {}
	page:Show()
	page:SetAlpha(1)
	from, othersFrom = from or 1, othersFrom or 1
	for i, fs in ipairs(strings) do
		fs.inkToken = (fs.inkToken or 0) + 1
		local token = fs.inkToken
		local len = #(fs:GetText() or "")
		if i < from then
			fs:SetAlphaGradient(len + 24, 1)
		else
			local start = (delay or 0) + (i - from) * LINE_STAGGER
			fs:SetAlphaGradient(0, 24)
			Tween(duration, function(p)
				if fs.inkToken == token then
					fs:SetAlphaGradient(math.floor(p * (len + 24)), 24)
				end
			end, function()
				if fs.inkToken == token then
					fs:SetAlphaGradient(len + 24, 1)
				end
			end, start)
		end
	end
	for i, region in ipairs(others) do
		if i < othersFrom then
			region:SetAlpha(1)
		else
			region:SetAlpha(0)
			Tween(duration * 0.8, function(p)
				region:SetAlpha(EaseOut(p))
			end, nil, (delay or 0) + (i - othersFrom) * LINE_STAGGER * 0.5)
		end
	end
end

local function FadeOut(page, duration, done)
	local from = page:GetAlpha()
	Tween(duration, function(p)
		page:SetAlpha(from * (1 - p))
	end, function()
		page:Hide()
		page:SetAlpha(1)
		if done then
			done()
		end
	end)
end

-- ---------------------------------------------------------------- turning sheet

local function ShowFrame(tex, index, shadow)
	local list = shadow and Art.shadows or Art.frames
	if shadow and not Art.shadows then
		error("BookArt.lua has no shadow frames; rerun tools/book/pack.py")
	end
	local f = list[index]
	if not f or f[1] == 0 then
		tex:Hide()
		return
	end
	tex:SetTexture(MEDIA .. (shadow and "shadow" or "turn") .. f[1] .. ".png")
	tex:SetTexCoord(f[2], f[3], f[4], f[5])
	local sw, sh = sheetLayer:GetSize()
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", sheetLayer, "TOPLEFT", f[6] * sw, -f[7] * sh)
	tex:SetSize((f[8] - f[6]) * sw, (f[9] - f[7]) * sh)
	tex:Show()
end

-- pos in [0, 1] along the turn.
local function SetSheet(pos, alpha)
	local n = #Art.frames
	local f = pos * (n - 1) + 1
	local i = math.floor(f)
	local frac = f - i
	ShowFrame(sheetA, i)
	sheetA:SetAlpha(alpha)
	ShowFrame(shadowA, i, true)
	if CROSSFADE and frac > 0.001 and i < n then
		ShowFrame(sheetB, i + 1)
		sheetB:SetAlpha(alpha * frac)
		-- Shadows are soft: blend them by weight instead of stacking.
		ShowFrame(shadowB, i + 1, true)
		shadowA:SetAlpha(alpha * (1 - frac))
		shadowB:SetAlpha(alpha * frac)
	else
		sheetB:Hide()
		shadowB:Hide()
		shadowA:SetAlpha(alpha)
	end
end

local function HideSheet()
	for _, t in ipairs({ shadowA, shadowB, sheetA, sheetB }) do
		t:Hide()
	end
end

-- Where the turning page's free edge is, roughly, for sparkles: x in root coordinates.
local function SheetEdgeX(pos)
	local gx = (Art.left[3] + Art.right[1]) / 2 * W
	local a = math.pi * pos
	local half = (Art.right[3] - Art.right[1]) * W
	return gx + math.cos(a) * half
end

-- Turn to a new spread. dir = 1 forward (right page over to the left), -1 back.
-- build(buffer) fills the hidden buffer's left and right pages.
function Book.Turn(dir, build)
	if busy then
		queued = { dir = dir, build = build }
		return
	end
	if state ~= "open" then
		build(Book.Buffer("hidden"))
		Book.Swap()
		return
	end
	local old = buffers[shown]
	local new = buffers[3 - shown]
	for _, side in ipairs({ "left", "right" }) do
		new[side]:Hide()
	end
	local good, err = pcall(build, new)
	if not good then
		Fail(err)
		return
	end
	busy = true
	if PlaySound and SOUNDKIT then
		PlaySound(SOUNDKIT.IG_ABILITY_PAGE_TURN or 836)
	end
	local lifting = dir > 0 and "right" or "left"
	local landing = dir > 0 and "left" or "right"
	-- 1. The sheet appears over the lifting page as its ink fades.
	FadeOut(old[lifting], SHEET_FADE)
	Tween(SHEET_FADE, function(p)
		SetSheet(dir > 0 and 0 or 1, p)
	end)
	-- 2. Turn. The new page underneath writes itself in once it is uncovered; as the sheet settles
	-- onto the other side its printed ink dissolves into the new page's (the last fifth of the
	-- turn is the page settling flat, so waiting for it to finish would show the stand-in text).
	local wroteUnder, landed = false, false
	local SETTLE = 0.8
	local function Land()
		landed = true
		old[landing]:Hide()
		WriteIn(new[landing], WRITE, 0)
		local lx = landing == "left" and (Art.left[1] + Art.left[3]) / 2 or (Art.right[1] + Art.right[3]) / 2
		Book.Burst(lx * W, -H * 0.5, {
			count = 16, kind = "spark", speed = 30, spreadX = W * 0.36, spreadY = H * 0.7, life = 1.0, size = 10,
			alpha = 0.6, jitter = 0.25,
		})
	end
	Tween(TURN, function(p)
		local pos = dir > 0 and p or 1 - p
		local alpha = 1
		if p > SETTLE then
			if not landed then
				Land()
			end
			alpha = 1 - EaseOut((p - SETTLE) / (1 - SETTLE))
		end
		SetSheet(pos, alpha)
		if not wroteUnder and p > 0.14 then
			wroteUnder = true
			WriteIn(new[lifting], WRITE, 0)
		end
		if p < SETTLE and math.random() < 0.45 then
			local x = SheetEdgeX(pos)
			Book.Burst(x, -H * (0.15 + math.random() * 0.7), {
				count = 1, kind = "spark", speed = 25, vy = 12, life = 0.9, size = 12, spread = 8,
			})
		end
	end, function()
		-- 3. Settled.
		if not landed then
			Land()
		end
		HideSheet()
		shown = 3 - shown
		busy = false
		Book.OnSettled()
		if queued then
			local q = queued
			queued = nil
			Book.Turn(q.dir, q.build)
		end
	end, SHEET_FADE * 0.6)
end

-- Replace the shown spread in place (no turn): a quick ink rewrite of the given sides (default
-- both). partial: only rewrite from each page's inkStart mark (search results while typing).
function Book.Rewrite(build, sides, partial)
	local b = buffers[shown]
	local good, err = pcall(build, b)
	if not good then
		Fail(err)
		return
	end
	local which = {}
	for _, side in ipairs(sides or { "left", "right" }) do
		which[side] = true
	end
	for _, side in ipairs({ "left", "right" }) do
		local page = b[side]
		if which[side] then
			WriteIn(page, 0.3, 0, partial and page.inkStart or 1, partial and page.othersStart or 1)
		else
			ShowAll(page)
		end
	end
end

-- Show the hidden buffer immediately.
function Book.Swap()
	local old = buffers[shown]
	old.left:Hide()
	old.right:Hide()
	shown = 3 - shown
	buffers[shown].left:Show()
	buffers[shown].right:Show()
	Book.OnSettled()
end

function Book.OnSettled()
	if ns.BookPages and ns.BookPages.OnSettled then
		ns.BookPages.OnSettled()
	end
end

function Book.IsBusy()
	return busy
end

-- ---------------------------------------------------------------- cover

-- The cover is a rigid board: project it with the render camera's perspective, in 16 strips so
-- the texture doesn't warp. gamma = 0 lying closed over the right page, pi lying open on the left.
local CAM_H = 3.6391 -- camera height over the table, in units where FRAME_W (2.62) is the image width
local FRAME_W = 2.62
local HINGE_Z = 0.097

local function Project(xw, yw, zw)
	-- xw, yw in world units from the spine center; returns root coords.
	local s = CAM_H / (CAM_H - zw) / (CAM_H / (CAM_H - HINGE_Z))
	local cx = (Art.left[3] + Art.right[1]) / 2 * W
	local cy = -(Art.right[2] + Art.right[4]) / 2 * H
	local px = W / FRAME_W
	return cx + xw * s * px, cy + yw * s * px
end

local function SetCover(gamma, alpha)
	local px = W / FRAME_W
	local gx = (Art.left[3] + Art.right[1]) / 2
	local boardW = (Art.book[3] - gx) * W / px -- world units
	local top = (Art.book[2] * H) / px
	local cy = (Art.right[2] + Art.right[4]) / 2 * H / px
	local yTop, yBot = cy - top, -(Art.book[4] * H / px - cy)
	local front = gamma < math.pi / 2
	local light = front and (1 - 0.28 * math.sin(gamma)) or (0.78 + 0.22 * -math.cos(gamma))
	local n = #coverStrips
	for i = 1, n do
		local u0, u1 = (i - 1) / n, i / n
		local function corner(u, yw)
			local d = u * boardW
			return Project(d * math.cos(gamma), yw, HINGE_Z + d * math.sin(gamma))
		end
		local x00, y00 = corner(u0, yTop)
		local x01, y01 = corner(u0, yBot)
		local x10, y10 = corner(u1, yTop)
		local x11, y11 = corner(u1, yBot)
		local tex = front and coverStrips[i] or backStrips[i]
		local other = front and backStrips[i] or coverStrips[i]
		other:Hide()
		-- The strip's own rect is its bounding box; vertex offsets bend it into the quad.
		local minX, maxX = math.min(x00, x01, x10, x11), math.max(x00, x01, x10, x11)
		local maxY, minY = math.max(y00, y01, y10, y11), math.min(y00, y01, y10, y11)
		tex:ClearAllPoints()
		tex:SetPoint("TOPLEFT", root, "TOPLEFT", minX, maxY)
		tex:SetSize(math.max(1, maxX - minX), math.max(1, maxY - minY))
		-- Vertex order: 1 upper left, 2 lower left, 3 upper right, 4 lower right.
		local lx, ly, rx, ry = x00, y00, x10, y10 -- top edge (inner, outer)
		local lbx, lby, rbx, rby = x01, y01, x11, y11
		if not front then
			-- Seen from below the strip runs the other way: swap so the quad isn't inside out.
			lx, ly, rx, ry = x10, y10, x00, y00
			lbx, lby, rbx, rby = x11, y11, x01, y01
		end
		local rune = runeStrips[i]
		for _, t in ipairs(front and { tex, rune } or { tex }) do
			t:ClearAllPoints()
			t:SetPoint("TOPLEFT", root, "TOPLEFT", minX, maxY)
			t:SetSize(math.max(1, maxX - minX), math.max(1, maxY - minY))
			t:SetVertexOffset(1, lx - minX, ly - maxY)
			t:SetVertexOffset(2, lbx - minX, lby - minY)
			t:SetVertexOffset(3, rx - maxX, ry - maxY)
			t:SetVertexOffset(4, rbx - maxX, rby - minY)
		end
		if front then
			rune:SetTexCoord(u0 * Art.glow.w / Art.glow.tw, u1 * Art.glow.w / Art.glow.tw, 0, Art.glow.h / Art.glow.th)
			rune:SetAlpha(alpha * runeLevel * math.max(0, 1 - gamma / 1.3))
			rune:Show()
		else
			rune:Hide()
		end
		if front then
			local c = Art.cover
			tex:SetTexCoord(u0, u1, 0, c.h / c.th)
		else
			-- The back is the left half of the spread, mirrored strip by strip.
			local s = Art.spread
			local bx0 = Art.book[1] * s.w / s.tw
			local gu = gx * s.w / s.tw
			local a = gu - (gu - bx0) * u1
			local b = gu - (gu - bx0) * u0
			tex:SetTexCoord(a, b, Art.book[2] * s.h / s.th, Art.book[4] * s.h / s.th)
		end
		local l = light * (0.94 + 0.06 * (front and (1 - u0) or u0))
		tex:SetVertexColor(l, l, l)
		tex:SetAlpha(alpha)
		tex:Show()
	end
	-- The glint only plays while the cover lies flat (it isn't split into strips).
	if gamma < 0.001 then
		local xA, yA = Project(0, yTop, HINGE_Z)
		local xB, yB = Project(boardW, yBot, HINGE_Z)
		glintTex:ClearAllPoints()
		glintTex:SetPoint("TOPLEFT", root, "TOPLEFT", xA, yA)
		glintTex:SetSize(xB - xA, yA - yB)
		glintTex:SetTexCoord(0, Art.glow.w / Art.glow.tw, 0, Art.glow.h / Art.glow.th)
		glintTex:Show()
		runesTex:ClearAllPoints()
		runesTex:SetAllPoints(glintTex)
	else
		glintTex:Hide()
	end
	-- The board's shadow falls on the right page while it stands up.
	local sh = math.sin(gamma)
	local reach = (Art.right[3] - Art.right[1]) * 0.6 * math.max(0.05, sh) ^ 0.8
	Place(coverShadow, { Art.right[1], Art.right[2], Art.right[1] + reach, Art.right[4] })
	coverShadow:SetAlpha(0.5 * sh * alpha)
end

local function HideCover()
	for i = 1, #coverStrips do
		coverStrips[i]:Hide()
		backStrips[i]:Hide()
		runeStrips[i]:Hide()
	end
	runesTex:Hide()
	glintTex:Hide()
	coverShadow:SetAlpha(0)
end

local function Glint(duration, delay)
	-- A band of light slides across the gold tooling.
	if not glintMask then
		return
	end
	Tween(duration, function(p)
		local w = glintTex:GetWidth()
		glintMask:ClearAllPoints()
		glintMask:SetSize(w * 0.5, glintTex:GetHeight() * 1.2)
		glintMask:SetPoint("CENTER", glintTex, "LEFT", -w * 0.3 + p * w * 1.6, 0)
	end, nil, delay)
end

-- ---------------------------------------------------------------- open / close

-- Right half of the spread only (the left half arrives with the cover).
local function SpreadHalf(rightOnly)
	local s = Art.spread
	local gx = (Art.left[3] + Art.right[1]) / 2
	spreadTex:ClearAllPoints()
	if rightOnly then
		spreadTex:SetPoint("TOPLEFT", root, "TOPLEFT", gx * W, 0)
		spreadTex:SetSize((1 - gx) * W, H)
		spreadTex:SetTexCoord(gx * s.w / s.tw, s.w / s.tw, 0, s.h / s.th)
	else
		spreadTex:SetAllPoints()
		spreadTex:SetTexCoord(0, s.w / s.tw, 0, s.h / s.th)
	end
end

function Book.IsOpen()
	return state == "open" or state == "opening"
end

-- Opens the book (if closed) and calls ready() once the pages can be written.
function Book.Open(build, ready)
	if not ns.BookArt then
		return false
	end
	if not Book.built then
		Build()
	end
	if state == "open" or state == "opening" then
		if build then
			Book.Turn(1, build)
		end
		return true
	end
	Reset()
	state = "opening"
	busy = true
	escProxy:Show()
	backdrop:Show()
	backdrop:SetAlpha(0)
	root:Show()
	root:SetAlpha(0)
	for i = 1, 2 do
		buffers[i].left:Hide()
		buffers[i].right:Hide()
	end
	if build then
		local good, err = pcall(build, buffers[3 - shown])
		if not good then
			Fail(err)
			return false
		end
	end
	SpreadHalf(true)
	local gx = (Art.left[3] + Art.right[1]) / 2
	local startShift = -((Art.book[3] - gx) * W) / 2
	root:ClearAllPoints()
	root:SetPoint("CENTER", startShift, -UIParent:GetHeight() * 0.01)
	runeLevel = 0.6
	SetCover(0, 1)
	if PlaySound and SOUNDKIT then
		PlaySound(SOUNDKIT.IG_SPELLBOOK_OPEN or 829)
	end
	-- The first time, the cover and page textures are still loading: wait for them unseen.
	local d = Book.warmed and 0 or 0.35
	Book.warmed = true
	-- 1. The closed book settles into view.
	Tween(OPEN_DROP, function(p)
		local e = EaseOut(p)
		backdrop:SetAlpha(e)
		root:SetAlpha(e)
		root:SetScale(1.06 - 0.06 * e)
	end, nil, d)
	Glint(0.7, d + OPEN_DROP * 0.6)
	-- 2. Runes flare, then the cover swings open and the book slides to the middle.
	Tween(0.35, function(p)
		runeLevel = 0.6 + 0.6 * math.sin(math.pi * p)
		SetCover(0, 1)
	end, nil, d + OPEN_DROP)
	local burstDone = false
	Tween(OPEN_SWING, function(p)
		local e = Ease(p)
		local gamma = math.pi * e
		SetCover(gamma, 1)
		root:ClearAllPoints()
		root:SetPoint("CENTER", startShift * (1 - e), -UIParent:GetHeight() * 0.01)
		-- Light spills out of the pages as they are uncovered.
		Place(pageGlow, Art.right)
		pageGlow:SetAlpha(0.16 * math.max(0, math.sin(math.pi * math.min(1, p * 1.3))))
		if not burstDone and p > 0.35 then
			burstDone = true
			Book.Burst((Art.right[1] + Art.right[3]) / 2 * W, -H * 0.5, {
				count = 40, kind = "spark", speed = 60, vy = 40, spreadX = W * 0.35, spreadY = H * 0.6,
				life = 1.6, size = 14, jitter = 0.4,
			})
			Book.Burst((Art.right[1] + Art.right[3]) / 2 * W, -H * 0.5, {
				count = 30, kind = "mote", speed = 20, vy = 30, spreadX = W * 0.35, spreadY = H * 0.6,
				life = 2.5, size = 8, alpha = 0.6, jitter = 0.6,
			})
		end
	end, function()
		HideCover()
		SpreadHalf(false)
		pageGlow:SetAlpha(0)
		state = "open"
		busy = false
		shown = 3 - shown
		WriteIn(buffers[shown].left, WRITE, 0)
		WriteIn(buffers[shown].right, WRITE, 0.12)
		-- A soft thump: a puff of dust at the outer edges.
		for _, x in ipairs({ Art.book[1], Art.book[3] }) do
			Book.Burst(x * W, -H * 0.5, { count = 10, kind = "mote", speed = 14, spreadY = H * 0.8, spreadX = 6,
				life = 1.2, size = 10, alpha = 0.3, color = { 0.9, 0.8, 0.65 } })
		end
		Book.OnSettled()
		if ready then
			ready()
		end
		if queued then
			local q = queued
			queued = nil
			Book.Turn(q.dir, q.build)
		end
	end, d + OPEN_DROP + 0.25)
	return true
end

CancelAll = function()
	for i = #tweens, 1, -1 do
		tweens[i] = nil
	end
end

-- Puts every layer back to rest: no cover, the whole spread, centered, full size, no sheet,
-- no pages. Safe to call at any point of an animation.
Reset = function()
	CancelAll()
	if not Book.built then
		return
	end
	HideCover()
	SpreadHalf(false)
	HideSheet()
	pageGlow:SetAlpha(0)
	root:ClearAllPoints()
	root:SetPoint("CENTER", 0, -UIParent:GetHeight() * 0.01)
	root:SetScale(1)
	root:SetAlpha(1)
	backdrop:SetAlpha(1)
	for i = 1, 2 do
		buffers[i].left:Hide()
		buffers[i].right:Hide()
	end
	for i = #particles, 1, -1 do
		particles[i].tex:Hide()
		pool[#pool + 1] = table.remove(particles, i)
	end
	busy = false
	queued = nil
end

function Book.Close()
	if state == "closed" or state == "closing" then
		return
	end
	-- Whatever was animating stops where it is; the book just fades from there.
	CancelAll()
	busy = false
	queued = nil
	state = "closing"
	escProxy:Hide()
	if PlaySound and SOUNDKIT then
		PlaySound(SOUNDKIT.IG_SPELLBOOK_CLOSE or 830)
	end
	if ns.BookPages and ns.BookPages.OnClose then
		ns.BookPages.OnClose()
	end
	local fromRoot, fromBack = root:GetAlpha(), backdrop:GetAlpha()
	local fromScale = root:GetScale()
	Tween(0.28, function(p)
		local e = EaseOut(p)
		root:SetAlpha(fromRoot * (1 - e))
		backdrop:SetAlpha(fromBack * (1 - e))
		root:SetScale(fromScale * (1 - 0.04 * e))
	end, function()
		root:Hide()
		backdrop:Hide()
		Reset()
		state = "closed"
	end)
end

-- An error in an animation: put everything away, report it once, and let the plain window
-- take over so the lookup still happens.
Fail = function(err)
	CancelAll()
	pcall(Reset)
	if root then
		root:Hide()
		backdrop:Hide()
		escProxy:Hide()
	end
	state = "closed"
	busy = false
	if ns.BookPages and ns.BookPages.OnFail then
		pcall(ns.BookPages.OnFail)
	end
	geterrorhandler()(err)
end

function Book.Toggle(build)
	if Book.IsOpen() then
		Book.Close()
	else
		Book.Open(build)
	end
end
