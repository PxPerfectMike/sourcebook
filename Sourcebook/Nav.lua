-- Sourcebook: the book's history, like a browser's: back, forward, and a breadcrumb trail you can
-- jump along. Pure; states are plain tables. The current state is live (paging the index edits it
-- in place); it is copied when you leave it, so history keeps where you were at that moment.

local _, ns = ...

local Nav = {}
Nav.__index = Nav
ns.Nav = Nav

Nav.MAX = 50

local function Copy(state)
	local c = {}
	for k, v in pairs(state) do
		c[k] = v
	end
	return c
end

function Nav.New()
	return setmetatable({ back = {}, forward = {}, current = nil }, Nav)
end

-- Two states are the same place in the book (ignoring scroll-like details such as plan counts).
function Nav.Same(a, b)
	if not (a and b) or a.kind ~= b.kind then
		return false
	end
	if a.kind == "index" then
		return a.query == b.query and a.category == b.category and a.sort == b.sort and a.page == b.page
	end
	return a.id == b.id and (a.sub or 1) == (b.sub or 1)
end

-- Goes somewhere new: the current place joins the back list and forward is cleared.
-- Going to where you already are does nothing and returns false.
function Nav:Go(state)
	if Nav.Same(self.current, state) then
		return false
	end
	if self.current then
		self.back[#self.back + 1] = Copy(self.current)
		if #self.back > Nav.MAX then
			table.remove(self.back, 1)
		end
	end
	self.forward = {}
	self.current = state
	return true
end

-- Replaces where you are without adding history (paging through the index, continuing an entry).
function Nav:Replace(state)
	self.current = state
end

function Nav:CanBack()
	return #self.back > 0
end

function Nav:CanForward()
	return #self.forward > 0
end

function Nav:Back()
	local prev = table.remove(self.back)
	if not prev then
		return nil
	end
	if self.current then
		self.forward[#self.forward + 1] = Copy(self.current)
	end
	self.current = prev
	return prev
end

function Nav:Forward()
	local nxt = table.remove(self.forward)
	if not nxt then
		return nil
	end
	if self.current then
		self.back[#self.back + 1] = Copy(self.current)
	end
	self.current = nxt
	return nxt
end

-- The trail: up to n states ending with the current one, oldest first. Each entry is
-- { state, steps } where steps is how many Back() calls reach it (0 = current).
function Nav:Crumbs(n)
	local out = {}
	local first = math.max(1, #self.back - (n - 2))
	for i = first, #self.back do
		out[#out + 1] = { state = self.back[i], steps = #self.back - i + 1 }
	end
	if self.current then
		out[#out + 1] = { state = self.current, steps = 0 }
	end
	return out
end

-- Goes back `steps` places at once (clicking a breadcrumb). Everything skipped goes to forward,
-- nearest first, so Forward() walks back along the same trail.
function Nav:BackSteps(steps)
	local target
	for _ = 1, steps do
		local prev = self:Back()
		if not prev then
			break
		end
		target = prev
	end
	return target
end

-- The most recent index state in history, if any (the Index link returns to your last search).
function Nav:LastIndex()
	if self.current and self.current.kind == "index" then
		return self.current
	end
	for i = #self.back, 1, -1 do
		if self.back[i].kind == "index" then
			return self.back[i]
		end
	end
	return nil
end
