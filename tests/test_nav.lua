local Nav = ns.Nav

local function Index(page, query)
	return { kind = "index", query = query or "", category = "all", sort = "name", page = page or 1 }
end

local function Item(id, sub)
	return { kind = "item", id = id, sub = sub }
end

local function Recipe(id, times)
	return { kind = "recipe", id = id, times = times or 1 }
end

-- Builds a history: each state is Go()'d in turn, so the last one ends up current.
local function Visit(nav, ...)
	for _, state in ipairs({ ... }) do
		nav:Go(state)
	end
	return nav
end

T("New: nothing to go back or forward to", function()
	local nav = Nav.New()
	eq(nav.current, nil)
	ok(not nav:CanBack(), "CanBack should be false")
	ok(not nav:CanForward(), "CanForward should be false")
	eq(nav:Back(), nil)
	eq(nav:Forward(), nil)
	eq(nav.back, {})
	eq(nav.forward, {})
	eq(nav.current, nil)
end)

T("Go: first state becomes current without adding history", function()
	local nav = Nav.New()
	ok(nav:Go(Index(1)) == true, "Go should return true")
	eq(nav.current, Index(1))
	eq(#nav.back, 0)
	ok(not nav:CanBack())
end)

T("Go: pushes previous current onto back, clears forward, returns true", function()
	local nav = Visit(Nav.New(), Index(1), Item(2589))
	ok(nav:Go(Recipe(2657)) == true)
	eq(nav.current, Recipe(2657))
	eq(nav.back, { Index(1), Item(2589) })
	ok(nav:CanBack())
	-- going forward into a new place after a Back() drops the forward trail
	nav:Back()
	ok(nav:CanForward())
	nav:Go(Item(2770))
	ok(not nav:CanForward(), "Go should clear forward")
	eq(nav.forward, {})
	eq(nav.current, Item(2770))
end)

T("Go: to the same place returns false and changes nothing", function()
	local nav = Visit(Nav.New(), Index(1), Item(2589))
	local backBefore = #nav.back
	ok(nav:Go(Item(2589)) == false, "Go to same place should return false")
	eq(#nav.back, backBefore, "back length should not change")
	eq(nav.current, Item(2589))
	eq(nav.back, { Index(1) })
	ok(not nav:CanForward())
end)

T("Go: same place does not clear forward", function()
	local nav = Visit(Nav.New(), Index(1), Item(2589))
	nav:Back()
	ok(nav:CanForward())
	ok(nav:Go(Index(1)) == false)
	ok(nav:CanForward(), "forward should survive a no-op Go")
	eq(nav.forward, { Item(2589) })
end)

T("Same: index states compare query, category, sort and page", function()
	ok(Nav.Same(Index(1, "copper"), Index(1, "copper")))
	ok(not Nav.Same(Index(1, "copper"), Index(1, "tin")), "query differs")
	ok(not Nav.Same(Index(1), { kind = "index", query = "", category = "gear", sort = "name", page = 1 }), "category differs")
	ok(not Nav.Same(Index(1), { kind = "index", query = "", category = "all", sort = "quality", page = 1 }), "sort differs")
	ok(not Nav.Same(Index(1), Index(2)), "page differs")
end)

T("Same: item states compare id and sub, nil sub counts as 1", function()
	ok(Nav.Same(Item(2589), Item(2589)))
	ok(Nav.Same(Item(2589), Item(2589, 1)), "nil sub equals sub 1")
	ok(Nav.Same(Item(2589, 1), Item(2589)), "sub 1 equals nil sub")
	ok(not Nav.Same(Item(2589, 2), Item(2589)), "sub 2 differs from nil")
	ok(not Nav.Same(Item(2589), Item(2770)), "id differs")
	ok(not Nav.Same(Item(2589, 2), Item(2589, 3)), "different subs differ")
end)

T("Same: recipe states ignore times", function()
	ok(Nav.Same(Recipe(2657, 1), Recipe(2657, 3)), "times should be ignored")
	ok(Nav.Same(Recipe(2657), Recipe(2657, 5)))
	ok(not Nav.Same(Recipe(2657), Recipe(2658)), "id differs")
end)

T("Same: different kinds are never the same", function()
	ok(not Nav.Same(Item(2657), Recipe(2657)), "item vs recipe with same id")
	ok(not Nav.Same(Index(1), Item(1)), "index vs item")
	ok(not Nav.Same({ kind = "item", id = 1 }, { kind = "recipe", id = 1 }))
end)

T("Same: nil arguments return false", function()
	ok(Nav.Same(nil, Index(1)) == false)
	ok(Nav.Same(Index(1), nil) == false)
	ok(Nav.Same(nil, nil) == false)
end)

T("Back then Forward round-trips the states in order", function()
	local nav = Visit(Nav.New(), Index(1), Item(2589), Recipe(2657), Item(2770))
	eq(nav:Back(), Recipe(2657))
	eq(nav:Back(), Item(2589))
	eq(nav:Back(), Index(1))
	ok(not nav:CanBack())
	eq(nav:Forward(), Item(2589))
	eq(nav:Forward(), Recipe(2657))
	eq(nav:Forward(), Item(2770))
	ok(not nav:CanForward())
	eq(nav.current, Item(2770))
	eq(nav.back, { Index(1), Item(2589), Recipe(2657) })
end)

T("Go after Back clears forward", function()
	local nav = Visit(Nav.New(), Index(1), Item(2589), Recipe(2657))
	nav:Back()
	nav:Back()
	ok(nav:CanForward())
	nav:Go(Item(2770))
	ok(not nav:CanForward())
	eq(nav:Back(), Index(1), "the trail after the new Go should be the place before the Back() calls")
end)

T("History holds copies: later edits to a state do not change Back", function()
	local first = Index(1)
	local nav = Visit(Nav.New(), first, Item(2589))
	first.page = 9
	eq(nav:Back(), Index(1), "back should return the page it had when left")
end)

T("History holds copies: edits to the passed-in state after Go do not change current history", function()
	local nav = Nav.New()
	local item = Item(2589)
	nav:Go(item)
	nav:Go(Item(2770))
	item.id = 1
	eq(nav:Back(), Item(2589))
end)

T("Replace changes current without touching back or forward", function()
	local nav = Visit(Nav.New(), Index(1), Item(2589), Item(2770))
	nav:Back()
	local backBefore, fwdBefore = #nav.back, #nav.forward
	nav:Replace(Index(3, "cloth"))
	eq(nav.current, Index(3, "cloth"))
	eq(#nav.back, backBefore)
	eq(#nav.forward, fwdBefore)
	eq(nav.back, { Index(1) })
	eq(nav.forward, { Item(2770) })
end)

T("Replace on a fresh history sets current only", function()
	local nav = Nav.New()
	nav:Replace(Index(2))
	eq(nav.current, Index(2))
	ok(not nav:CanBack())
	ok(not nav:CanForward())
end)

T("MAX is 50", function()
	eq(Nav.MAX, 50)
end)

T("Back holds at most MAX entries and drops the oldest", function()
	local nav = Nav.New()
	local total = Nav.MAX + 5
	for i = 1, total do
		nav:Go(Item(i))
	end
	eq(#nav.back, Nav.MAX)
	-- the first Go only sets current, so 54 states were pushed; the 4 oldest (1-4) were dropped
	eq(nav.back[1], Item(5), "oldest entries should be dropped")
	eq(nav.back[#nav.back], Item(total - 1), "newest entry before current")
	eq(nav.current, Item(total))
end)

T("Crumbs: returns the last n states oldest first with steps", function()
	local nav = Visit(Nav.New(), Item(1), Item(2), Item(3), Item(4))
	-- back = {1,2,3}, current = 4
	eq(nav:Crumbs(3), {
		{ state = Item(2), steps = 2 },
		{ state = Item(3), steps = 1 },
		{ state = Item(4), steps = 0 },
	})
end)

T("Crumbs: a large n returns the whole trail", function()
	local nav = Visit(Nav.New(), Item(1), Item(2), Item(3), Item(4))
	eq(nav:Crumbs(10), {
		{ state = Item(1), steps = 3 },
		{ state = Item(2), steps = 2 },
		{ state = Item(3), steps = 1 },
		{ state = Item(4), steps = 0 },
	})
end)

T("Crumbs: empty history returns just the current with 0 steps", function()
	local nav = Visit(Nav.New(), Index(1))
	eq(nav:Crumbs(5), { { state = Index(1), steps = 0 } })
	eq(Nav.New():Crumbs(5), {})
end)

T("BackSteps: lands the given number of steps back", function()
	local nav = Visit(Nav.New(), Item(1), Item(2), Item(3), Item(4))
	eq(nav:BackSteps(2), Item(2))
	eq(nav.current, Item(2))
	eq(nav.back, { Item(1) })
end)

T("BackSteps: skipped states go to forward, nearest first", function()
	local nav = Visit(Nav.New(), Item(1), Item(2), Item(3), Item(4))
	nav:BackSteps(2)
	eq(nav:Forward(), Item(3), "first Forward should be the nearer skipped state")
	eq(nav:Forward(), Item(4))
	ok(not nav:CanForward())
	eq(nav.current, Item(4))
end)

T("BackSteps: larger than history stops at the oldest state", function()
	local nav = Visit(Nav.New(), Item(1), Item(2), Item(3))
	eq(nav:BackSteps(10), Item(1))
	eq(nav.current, Item(1))
	ok(not nav:CanBack())
	eq(nav:Forward(), Item(2))
	eq(nav:Forward(), Item(3))
end)

T("BackSteps: with no history returns nil and changes nothing", function()
	local nav = Visit(Nav.New(), Index(1))
	eq(nav:BackSteps(3), nil)
	eq(nav.current, Index(1))
	ok(not nav:CanForward())
end)

T("LastIndex: returns current when it is an index", function()
	local nav = Visit(Nav.New(), Item(1), Index(4, "tin"))
	eq(nav:LastIndex(), Index(4, "tin"))
end)

T("LastIndex: otherwise the most recent index in back", function()
	local nav = Visit(Nav.New(), Index(1), Item(2), Index(5, "copper"), Recipe(3), Item(4))
	eq(nav:LastIndex(), Index(5, "copper"))
end)

T("LastIndex: nil when there is no index state", function()
	local nav = Visit(Nav.New(), Item(1), Recipe(2))
	eq(nav:LastIndex(), nil)
	eq(Nav.New():LastIndex(), nil)
end)
