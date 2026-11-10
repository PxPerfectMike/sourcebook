local Library = ns.Library

T("Meta and Category", function()
	eq(Library.Meta(2589), { class = 7, subclass = 5, quality = 1, itemLevel = 5, requiredLevel = 0 })
	eq(Library.Category(2589), "reagent")
	eq(Library.Category(2770), "reagent")
	eq(Library.Category(1716), "gear")
	eq(Library.Category(999999999), "other")
	local recipeItem = next(ns.RecipeItems)
	if Library.Meta(recipeItem) then
		eq(Library.Category(recipeItem), "recipe")
	end
end)

T("SourceCount counts totals, not just the listed best", function()
	ok(Library.SourceCount(2589) > 600, "Linen Cloth drops from hundreds of creatures")
	ok(Library.SourceCount(2770) > 700)
	eq(Library.SourceCount(999999999), 0)
end)

T("Browse with a query puts the exact name first", function()
	local ids = Library.Browse("copper ore", "all", "name")
	eq(ids[1], 2770)
	local bars = Library.Browse("copper", "reagent", "name")
	ok(#bars >= 3)
	for _, id in ipairs(bars) do
		eq(Library.Category(id), "reagent")
	end
end)

T("Browse sorts by name, quality, level and sources", function()
	local byName = Library.Browse("cloth", "all", "name")
	for i = 2, #byName do
		local a, b = SourcebookLoot.names[byName[i - 1]]:lower(), SourcebookLoot.names[byName[i]]:lower()
		ok(a <= b, a .. " before " .. b)
	end
	local byQuality = Library.Browse("", "gear", "quality")
	ok(#byQuality > 1000)
	ok(Library.Meta(byQuality[1]).quality >= Library.Meta(byQuality[#byQuality]).quality)
	local bySources = Library.Browse("cloth", "reagent", "sources")
	ok(Library.SourceCount(bySources[1]) >= Library.SourceCount(bySources[#bySources]))
	local byLevel = Library.Browse("", "gear", "level")
	ok(Library.Meta(byLevel[1]).requiredLevel >= Library.Meta(byLevel[#byLevel]).requiredLevel)
end)

T("Browse with no query lists everything in a category", function()
	local all = Library.Browse(nil, "all", "name")
	local recipes = Library.Browse("", "recipe", "name")
	ok(#all > 5000)
	ok(#recipes > 100 and #recipes < #all)
	eq(Library.Browse("zzqqxx", "all", "name"), {})
end)

T("Page slices and clamps", function()
	local list = {}
	for i = 1, 25 do
		list[i] = i
	end
	eq({ Library.Page(list, 10, 1) }, { { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, 1, 3 })
	eq({ Library.Page(list, 10, 3) }, { { 21, 22, 23, 24, 25 }, 3, 3 })
	eq({ Library.Page(list, 10, 9) }, { { 21, 22, 23, 24, 25 }, 3, 3 })
	eq({ Library.Page(list, 10, 0) }, { { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, 1, 3 })
	eq({ Library.Page({}, 10, 1) }, { {}, 1, 1 })
end)

T("Flow fills pages in order and keeps headers with their first row", function()
	local pageOf, pages = Library.Flow({ 10, 10, 10, 10, 10 }, 25)
	eq(pageOf, { 1, 1, 2, 2, 3 })
	eq(pages, 3)
	-- header (3) must stay with row 4: they move to page 2 together
	pageOf = Library.Flow({ 10, 10, 2, 10 }, 25, { [3] = true })
	eq(pageOf, { 1, 1, 2, 2 })
	-- chains of keeps move as one block
	pageOf = Library.Flow({ 20, 2, 2, 10 }, 25, { [2] = true, [3] = true })
	eq(pageOf, { 1, 2, 2, 2 })
	-- an element bigger than a page still gets placed
	pageOf, pages = Library.Flow({ 5, 40, 5 }, 25)
	eq(pageOf, { 1, 2, 3 })
	eq(pages, 3)
	eq({ Library.Flow({}, 25) }, { {}, 0 })
end)
